## BMP codec — references/image/src/codecs/bmp/ (decoder 3170, encoder 750)
## Supports: file header + DIB 12/40/108/124, BI_RGB/RLE8/RLE4/BITFIELDS/ALPHABITFIELDS,
## depths 1/4/8 (palette) /16 (555+bitfields) /24 /32, top-down + bottom-up.
import std/bitops
import ../color
import ../error
import ../buffer
import ../dynamic

const
  BiRgb* = 0'u32
  BiRle8* = 1'u32
  BiRle4* = 2'u32
  BiBitfields* = 3'u32
  BiAlphaBitfields* = 6'u32

func u16le(d: openArray[uint8], off: int): uint16 =
  uint16(d[off]) or (uint16(d[off+1]) shl 8)
func u32le(d: openArray[uint8], off: int): uint32 =
  uint32(d[off]) or (uint32(d[off+1]) shl 8) or (uint32(d[off+2]) shl 16) or
    (uint32(d[off+3]) shl 24)
func i32le(d: openArray[uint8], off: int): int32 = cast[int32](u32le(d, off))

func scaleBits(v: uint32, len: int): uint8 =
  if len == 0: return 0
  if len >= 8:
    let s = len - 8
    return uint8((v shr s) and 0xFF)
  let max = (1'u32 shl len) - 1
  uint8((v * 255 + max div 2) div max)

proc maskInfo(mask: uint32): tuple[shift, len: int] =
  if mask == 0: return (0, 0)
  let s = countTrailingZeroBits(mask)
  var l = 0
  var m = mask shr s
  while (m and 1) == 1:
    inc l; m = m shr 1
  (s, l)

proc decodeBmp*(data: seq[uint8]): ImageResult[DynamicImage] =
  if data.len < 14 or data[0] != uint8('B') or data[1] != uint8('M'):
    return err[DynamicImage](decodingError("bmp: bad signature"))
  let dataOff = int(u32le(data, 10))
  if data.len < 18:
    return err[DynamicImage](decodingError("bmp: truncated header"))
  let dibSize = u32le(data, 14)
  var width, height: int32
  var planes: uint16
  var bpp: uint16
  var compression = BiRgb
  var colorsUsed: uint32 = 0
  var rMask = 0'u32; var gMask = 0'u32; var bMask = 0'u32; var aMask = 0'u32
  var hasMasks = false
  var paletteOff = 14 + int(dibSize)
  if dibSize == 12:
    if data.len < 26:
      return err[DynamicImage](decodingError("bmp: truncated core header"))
    width = int32(u16le(data, 18)); height = int32(u16le(data, 20))
    planes = u16le(data, 22); bpp = u16le(data, 24)
  elif dibSize in [40'u32, 52, 56, 108, 124]:
    if data.len < 14 + int(dibSize):
      return err[DynamicImage](decodingError("bmp: truncated info header"))
    width = i32le(data, 18); height = i32le(data, 22)
    planes = u16le(data, 26); bpp = u16le(data, 28)
    compression = u32le(data, 30)
    colorsUsed = u32le(data, 46)
    if dibSize >= 52 and compression in [BiBitfields, BiAlphaBitfields]:
      if data.len < 14 + 40 + 12:
        return err[DynamicImage](decodingError("bmp: truncated bitfields"))
      # masks follow BITMAPINFOHEADER for V2+; for V1 (40) they follow header too
      rMask = u32le(data, 54); gMask = u32le(data, 58); bMask = u32le(data, 62)
      hasMasks = true
      paletteOff = 14 + 40 + 12
      # V4+ headers always carry an alpha mask slot; reference encoder writes
      # 4 masks with compression BI_BITFIELDS, so read it whenever present.
      if dibSize >= 108 and data.len >= 14 + 40 + 16:
        aMask = u32le(data, 66)
        paletteOff = 14 + 40 + 16
      elif dibSize >= 56 and compression == BiAlphaBitfields:
        if data.len < 14 + 40 + 16:
          return err[DynamicImage](decodingError("bmp: truncated alpha mask"))
        aMask = u32le(data, 66)
        paletteOff = 14 + 40 + 16
    elif dibSize == 40 and compression in [BiBitfields, BiAlphaBitfields]:
      rMask = u32le(data, 54); gMask = u32le(data, 58); bMask = u32le(data, 62)
      hasMasks = true
      paletteOff = 14 + 40 + 12
      if compression == BiAlphaBitfields:
        if data.len < 14 + 40 + 16:
          return err[DynamicImage](decodingError("bmp: truncated alpha mask"))
        aMask = u32le(data, 66)
        paletteOff = 14 + 40 + 16
  else:
    return err[DynamicImage](unsupportedError(ukGenericFeature, "bmp: DIB size " & $dibSize))
  if planes != 1:
    return err[DynamicImage](decodingError("bmp: planes must be 1"))
  if width <= 0 or height == 0:
    return err[DynamicImage](decodingError("bmp: bad dimensions"))
  let topDown = height < 0
  let w = int(width)
  let h = abs(int(height))
  if w > 0xFFFF or h > 0xFFFF:
    return err[DynamicImage](decodingError("bmp: dimensions too large"))
  let n = w * h
  # palette
  var palette: seq[tuple[r, g, b: uint8]] = @[]
  if bpp <= 8:
    var numColors = int(colorsUsed)
    if numColors == 0: numColors = 1 shl int(bpp)
    let entrySize = if dibSize == 12: 3 else: 4
    if paletteOff + numColors * entrySize > data.len:
      return err[DynamicImage](decodingError("bmp: truncated palette"))
    for i in 0..<numColors:
      let o = paletteOff + i * entrySize
      palette.add((data[o+2], data[o+1], data[o]))
  if compression in [4'u32, 5, 11, 12, 13]:
    return err[DynamicImage](unsupportedError(ukGenericFeature, "bmp: compression " & $compression))
  # helper to fetch row bytes
  if compression == BiRgb or compression == BiBitfields or compression == BiAlphaBitfields:
    let rowStride = ((int(bpp) * w + 31) div 32) * 4
    if dataOff + rowStride * h > data.len + rowStride: # allow slight overrun check per row below
      discard
    # 16-bit defaults
    if bpp == 16 and not hasMasks:
      rMask = 0x7C00'u32; gMask = 0x03E0'u32; bMask = 0x001F'u32
      hasMasks = true
    if bpp == 16 and hasMasks and rMask == 0 and gMask == 0 and bMask == 0:
      rMask = 0x7C00'u32; gMask = 0x03E0'u32; bMask = 0x001F'u32
    if bpp == 32 and compression == BiRgb and not hasMasks:
      # BGRA, alpha preserved if nonzero else opaque? Preserve byte; tests use 255.
      var px = newSeq[Rgba[uint8]](n)
      for y in 0..<h:
        let srcY = if topDown: y else: h - 1 - y
        let rowOff = dataOff + srcY * rowStride
        if rowOff + w * 4 > data.len:
          return err[DynamicImage](decodingError("bmp: truncated 32-bit"))
        for x in 0..<w:
          let o = rowOff + x * 4
          px[y*w+x] = Rgba[uint8](data: [data[o+2], data[o+1], data[o], data[o+3]])
      # if all alpha are 0, treat as opaque (common for BI_RGB files)
      var allZero = true
      for p in px:
        if p.data[3] != 0: allZero = false; break
      if allZero:
        var rgb = newSeq[Rgb[uint8]](n)
        for i, p in px: rgb[i] = Rgb[uint8](data: [p.data[0], p.data[1], p.data[2]])
        return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(rgb))))
      return ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif bpp == 32 and hasMasks:
      let (rs, rl) = maskInfo(rMask); let (gs, gl) = maskInfo(gMask)
      let (bs, bl) = maskInfo(bMask); let (alS, alL) = maskInfo(aMask)
      let useAlpha = alL > 0
      if useAlpha:
        var px = newSeq[Rgba[uint8]](n)
        for y in 0..<h:
          let srcY = if topDown: y else: h - 1 - y
          let rowOff = dataOff + srcY * rowStride
          if rowOff + w * 4 > data.len:
            return err[DynamicImage](decodingError("bmp: truncated 32-bit"))
          for x in 0..<w:
            let v = u32le(data, rowOff + x * 4)
            let a = if alL == 0: 255'u8 else: scaleBits((v and aMask) shr uint32(alS), alL)
            px[y*w+x] = Rgba[uint8](data: [scaleBits((v and rMask) shr uint32(rs), rl),
              scaleBits((v and gMask) shr uint32(gs), gl),
              scaleBits((v and bMask) shr uint32(bs), bl), a])
        return ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[Rgb[uint8]](n)
        for y in 0..<h:
          let srcY = if topDown: y else: h - 1 - y
          let rowOff = dataOff + srcY * rowStride
          if rowOff + w * 4 > data.len:
            return err[DynamicImage](decodingError("bmp: truncated 32-bit"))
          for x in 0..<w:
            let v = u32le(data, rowOff + x * 4)
            px[y*w+x] = Rgb[uint8](data: [scaleBits((v and rMask) shr uint32(rs), rl),
              scaleBits((v and gMask) shr uint32(gs), gl),
              scaleBits((v and bMask) shr uint32(bs), bl)])
        return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif bpp == 24:
      var px = newSeq[Rgb[uint8]](n)
      for y in 0..<h:
        let srcY = if topDown: y else: h - 1 - y
        let rowOff = dataOff + srcY * rowStride
        if rowOff + w * 3 > data.len:
          return err[DynamicImage](decodingError("bmp: truncated 24-bit"))
        for x in 0..<w:
          let o = rowOff + x * 3
          px[y*w+x] = Rgb[uint8](data: [data[o+2], data[o+1], data[o]])
      return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif bpp == 16:
      let (rs, rl) = maskInfo(rMask); let (gs, gl) = maskInfo(gMask)
      let (bs, bl) = maskInfo(bMask)
      var px = newSeq[Rgb[uint8]](n)
      for y in 0..<h:
        let srcY = if topDown: y else: h - 1 - y
        let rowOff = dataOff + srcY * rowStride
        if rowOff + w * 2 > data.len:
          return err[DynamicImage](decodingError("bmp: truncated 16-bit"))
        for x in 0..<w:
          let v = uint32(u16le(data, rowOff + x * 2))
          px[y*w+x] = Rgb[uint8](data: [scaleBits((v and rMask) shr uint32(rs), rl),
            scaleBits((v and gMask) shr uint32(gs), gl),
            scaleBits((v and bMask) shr uint32(bs), bl)])
      return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif bpp in [1'u16, 4, 8]:
      let bitsPerRow = int(bpp) * w
      var px = newSeq[Rgb[uint8]](n)
      for y in 0..<h:
        let srcY = if topDown: y else: h - 1 - y
        let rowOff = dataOff + srcY * rowStride
        if rowOff + ((bitsPerRow + 7) div 8) > data.len:
          return err[DynamicImage](decodingError("bmp: truncated palette data"))
        for x in 0..<w:
          var idx = 0
          case bpp
          of 8: idx = int(data[rowOff + x])
          of 4:
            let b = data[rowOff + x div 2]
            idx = if (x mod 2) == 0: int(b shr 4) else: int(b and 0xF)
          of 1:
            let b = data[rowOff + x div 8]
            idx = int((b shr (7 - (x mod 8))) and 1)
          else: discard
          if idx >= palette.len:
            return err[DynamicImage](decodingError("bmp: bad palette index"))
          let c = palette[idx]
          px[y*w+x] = Rgb[uint8](data: [c.r, c.g, c.b])
      return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    else:
      return err[DynamicImage](unsupportedError(ukColor, "bmp: bit depth " & $bpp))
  elif compression == BiRle8:
    # RLE8 decode to indices then palette
    var indices = newSeq[uint8](n)
    var x = 0; var y = 0
    var p = dataOff
    let absMode = proc() = discard
    while y < h:
      if p + 1 >= data.len:
        return err[DynamicImage](decodingError("bmp: truncated RLE8"))
      let count = int(data[p]); let val = data[p+1]; p += 2
      if count > 0:
        for _ in 0..<count:
          if x >= w: break
          let yy = if topDown: y else: h - 1 - y
          indices[yy*w+x] = val
          inc x
      else:
        if val == 0: inc y; x = 0
        elif val == 1: break
        elif val == 2:
          if p + 1 >= data.len:
            return err[DynamicImage](decodingError("bmp: truncated RLE8 delta"))
          x += int(data[p]); y += int(data[p+1]); p += 2
        else:
          let k = int(val)
          if p + k > data.len:
            return err[DynamicImage](decodingError("bmp: truncated RLE8 abs"))
          for i in 0..<k:
            if x < w:
              let yy = if topDown: y else: h - 1 - y
              indices[yy*w+x] = data[p+i]
              inc x
          p += k
          if (k mod 2) == 1: inc p
    var px = newSeq[Rgb[uint8]](n)
    for i in 0..<n:
      if int(indices[i]) >= palette.len:
        return err[DynamicImage](decodingError("bmp: bad palette index"))
      let c = palette[indices[i]]
      px[i] = Rgb[uint8](data: [c.r, c.g, c.b])
    return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  elif compression == BiRle4:
    var indices = newSeq[uint8](n)
    var x = 0; var y = 0
    var p = dataOff
    while y < h:
      if p + 1 >= data.len:
        return err[DynamicImage](decodingError("bmp: truncated RLE4"))
      let count = int(data[p]); let val = data[p+1]; p += 2
      if count > 0:
        let hi = (val shr 4) and 0xF; let lo = val and 0xF
        for i in 0..<count:
          if x >= w: break
          let yy = if topDown: y else: h - 1 - y
          indices[yy*w+x] = if (i mod 2) == 0: hi else: lo
          inc x
      else:
        if val == 0: inc y; x = 0
        elif val == 1: break
        elif val == 2:
          if p + 1 >= data.len:
            return err[DynamicImage](decodingError("bmp: truncated RLE4 delta"))
          x += int(data[p]); y += int(data[p+1]); p += 2
        else:
          let k = int(val)
          let bytes = (k + 1) div 2
          if p + bytes > data.len:
            return err[DynamicImage](decodingError("bmp: truncated RLE4 abs"))
          for i in 0..<k:
            if x < w:
              let b = data[p + i div 2]
              let nib = if (i mod 2) == 0: (b shr 4) and 0xF else: b and 0xF
              let yy = if topDown: y else: h - 1 - y
              indices[yy*w+x] = nib
              inc x
          p += bytes
          if (bytes mod 2) == 1: inc p
    var px = newSeq[Rgb[uint8]](n)
    for i in 0..<n:
      if int(indices[i]) >= palette.len:
        return err[DynamicImage](decodingError("bmp: bad palette index"))
      let c = palette[indices[i]]
      px[i] = Rgb[uint8](data: [c.r, c.g, c.b])
    return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  err[DynamicImage](unsupportedError(ukGenericFeature, "bmp: compression " & $compression))

proc encodeBmpRgb8*(img: RgbImage): seq[uint8] =
  let w = int(img.width); let h = int(img.height)
  let rowStride = ((24 * w + 31) div 32) * 4
  let dataSize = rowStride * h
  result = newSeq[uint8](14 + 40 + dataSize)
  result[0] = uint8('B'); result[1] = uint8('M')
  let fs = uint32(result.len)
  result[2] = uint8(fs and 0xFF); result[3] = uint8((fs shr 8) and 0xFF)
  result[4] = uint8((fs shr 16) and 0xFF); result[5] = uint8((fs shr 24) and 0xFF)
  result[10] = 54
  result[14] = 40
  result[18] = uint8(w and 0xFF); result[19] = uint8((w shr 8) and 0xFF)
  result[20] = uint8((w shr 16) and 0xFF); result[21] = uint8((w shr 24) and 0xFF)
  result[22] = uint8(h and 0xFF); result[23] = uint8((h shr 8) and 0xFF)
  result[24] = uint8((h shr 16) and 0xFF); result[25] = uint8((h shr 24) and 0xFF)
  result[26] = 1
  result[28] = 24
  for y in 0..<h:
    let srcY = h - 1 - y
    let rowOff = 54 + y * rowStride
    for x in 0..<w:
      let p = img.pixels[srcY*w+x]
      let o = rowOff + x * 3
      result[o] = p.data[2]; result[o+1] = p.data[1]; result[o+2] = p.data[0]

proc encodeBmpRgba8*(img: RgbaImage): seq[uint8] =
  let w = int(img.width); let h = int(img.height)
  let dataSize = w * h * 4
  result = newSeq[uint8](14 + 108 + dataSize)
  result[0] = uint8('B'); result[1] = uint8('M')
  let fs = uint32(result.len)
  result[2] = uint8(fs and 0xFF); result[3] = uint8((fs shr 8) and 0xFF)
  result[4] = uint8((fs shr 16) and 0xFF); result[5] = uint8((fs shr 24) and 0xFF)
  result[10] = 122
  result[14] = 108
  result[18] = uint8(w and 0xFF); result[19] = uint8((w shr 8) and 0xFF)
  result[20] = uint8((w shr 16) and 0xFF); result[21] = uint8((w shr 24) and 0xFF)
  result[22] = uint8(h and 0xFF); result[23] = uint8((h shr 8) and 0xFF)
  result[24] = uint8((h shr 16) and 0xFF); result[25] = uint8((h shr 24) and 0xFF)
  result[26] = 1
  result[28] = 32
  result[30] = 3 # BI_BITFIELDS
  # masks R,G,B,A
  result[54] = 0x00; result[55] = 0x00; result[56] = 0xFF; result[57] = 0x00
  result[58] = 0x00; result[59] = 0xFF; result[60] = 0x00; result[61] = 0x00
  result[62] = 0xFF; result[63] = 0x00; result[64] = 0x00; result[65] = 0x00
  result[66] = 0x00; result[67] = 0x00; result[68] = 0x00; result[69] = 0xFF
  for y in 0..<h:
    let srcY = h - 1 - y
    let rowOff = 122 + y * w * 4
    for x in 0..<w:
      let p = img.pixels[srcY*w+x]
      let o = rowOff + x * 4
      result[o] = p.data[2]; result[o+1] = p.data[1]; result[o+2] = p.data[0]; result[o+3] = p.data[3]
