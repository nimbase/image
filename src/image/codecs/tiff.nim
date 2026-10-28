## TIFF codec — references/image/src/codecs/tiff.rs (849) + tiff@0.11.2
## Classic TIFF (II/MM, 42). Strips + tiles, chunky + planar, compressions
## None/LZW/Deflate/PackBits, predictors, photometrics incl. YCbCr/CMYK/palette.
## JPEG-in-TIFF and BigTIFF return Unsupported.
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic
import ../zlibwrap
import ../lzw

const
  TCompression* = 259'u16
  TPhotometric* = 262'u16
  TStripOffsets* = 273'u16
  TRowsPerStrip* = 278'u16
  TStripByteCounts* = 279'u16
  TTileWidth* = 322'u16
  TTileLength* = 323'u16
  TTileOffsets* = 324'u16
  TTileByteCounts* = 325'u16

type
  TiffEndian = enum teLittle, teBig
  TiffValue = object
    typ: uint16
    count: uint32
    data: seq[uint8] # raw value bytes in file order
  TiffIfd = object
    entries: seq[tuple[tag: uint16, v: TiffValue]]
    nextOff: uint32

proc rd16(d: openArray[uint8], off: int, e: TiffEndian): uint16 =
  if e == teLittle: uint16(d[off]) or (uint16(d[off+1]) shl 8)
  else: (uint16(d[off]) shl 8) or uint16(d[off+1])

proc rd32(d: openArray[uint8], off: int, e: TiffEndian): uint32 =
  if e == teLittle:
    uint32(d[off]) or (uint32(d[off+1]) shl 8) or
      (uint32(d[off+2]) shl 16) or (uint32(d[off+3]) shl 24)
  else:
    (uint32(d[off]) shl 24) or (uint32(d[off+1]) shl 16) or
      (uint32(d[off+2]) shl 8) or uint32(d[off+3])

func typeSize(t: uint16): int =
  case t
  of 1, 2, 6, 7: 1
  of 3, 8: 2
  of 4, 9, 11, 13: 4
  of 5, 10, 12: 8
  else: 0

proc parseIfd(data: seq[uint8], off: int, e: TiffEndian): ImageResult[TiffIfd] =
  if off + 2 > data.len:
    return err[TiffIfd](decodingError("tiff: truncated IFD"))
  let n = int(rd16(data, off, e))
  if off + 2 + n * 12 + 4 > data.len:
    return err[TiffIfd](decodingError("tiff: truncated IFD entries"))
  var entries: seq[tuple[tag: uint16, v: TiffValue]] = @[]
  for i in 0..<n:
    let o = off + 2 + i * 12
    let tag = rd16(data, o, e)
    let typ = rd16(data, o + 2, e)
    let count = rd32(data, o + 4, e)
    let sz = typeSize(typ)
    if sz == 0:
      return err[TiffIfd](unsupportedError(ukGenericFeature, "tiff: field type " & $typ))
    let total = uint64(sz) * uint64(count)
    if total > uint64(data.len):
      return err[TiffIfd](decodingError("tiff: field too large"))
    var raw = newSeq[uint8](int(total))
    if total <= 4:
      for k in 0..<int(total): raw[k] = data[o+8+k]
    else:
      let voff = int(rd32(data, o + 8, e))
      if voff + int(total) > data.len:
        return err[TiffIfd](decodingError("tiff: field offset OOB"))
      for k in 0..<int(total): raw[k] = data[voff+k]
    entries.add((tag, TiffValue(typ: typ, count: count, data: raw)))
  let nextOff = rd32(data, off + 2 + n * 12, e)
  ok(TiffIfd(entries: entries, nextOff: nextOff))

proc find(ifd: TiffIfd, tag: uint16): tuple[found: bool, v: TiffValue] =
  for e in ifd.entries:
    if e.tag == tag: return (true, e.v)
  (false, TiffValue())

proc valU32(v: TiffValue, idx: int, e: TiffEndian): uint32 =
  case v.typ
  of 3: uint32(rd16(v.data, idx * 2, e))
  of 4: rd32(v.data, idx * 4, e)
  of 1, 7: uint32(v.data[idx])
  else: 0

proc valU16(v: TiffValue, idx: int, e: TiffEndian): uint16 =
  case v.typ
  of 3: rd16(v.data, idx * 2, e)
  of 1, 7: uint16(v.data[idx])
  of 4: uint16(rd32(v.data, idx * 4, e) and 0xFFFF)
  else: 0

proc getU32(ifd: TiffIfd, tag: uint16, e: TiffEndian, dflt: uint32): uint32 =
  let (f, v) = ifd.find(tag)
  if not f or v.count == 0: dflt else: valU32(v, 0, e)

proc getArray(ifd: TiffIfd, tag: uint16, e: TiffEndian, n: int,
    dflt: uint32): seq[uint32] =
  let (f, v) = ifd.find(tag)
  if not f or v.count == 0:
    result = newSeq[uint32](n)
    for i in 0..<n: result[i] = dflt
  elif int(v.count) == 1:
    result = newSeq[uint32](n)
    for i in 0..<n: result[i] = valU32(v, 0, e)
  else:
    result = newSeq[uint32](min(n, int(v.count)))
    for i in 0..<result.len: result[i] = valU32(v, i, e)

proc unpackBits(row: openArray[uint8], n: int, bits: int,
    fillLsb: bool): seq[uint16] =
  ## Unpack n samples of `bits` width (1/2/4) to uint16 values.
  result = newSeq[uint16](n)
  var bi = 0
  for i in 0..<n:
    var v = 0
    for k in 0..<bits:
      let bit =
        if not fillLsb:
          int((row[bi div 8] shr uint8(7 - (bi mod 8))) and 1)
        else:
          int((row[bi div 8] shr uint8(bi mod 8)) and 1)
      v = (v shl 1) or bit
      inc bi
    result[i] = uint16(v)

proc undoPredictor(data: var seq[uint8], w, channels, bits: int) =
  ## Horizontal differencing (predictor 2) for 8/16-bit integer samples.
  if bits == 8:
    let stride = w * channels
    for i in channels..<data.len:
      if (i mod stride) >= channels:
        data[i] = uint8((int(data[i]) + int(data[i-channels])) and 0xFF)
  elif bits == 16:
    let stride = w * channels * 2
    for i in 0..<data.len div 2:
      let bytePos = i * 2
      if (i mod (w * channels)) >= channels:
        let prev = (uint16(data[bytePos-2*channels]) shl 8) or
          uint16(data[bytePos-2*channels+1])
        let cur = (uint16(data[bytePos]) shl 8) or uint16(data[bytePos+1])
        let s = uint16((cur + prev) and 0xFFFF)
        data[bytePos] = uint8((s shr 8) and 0xFF)
        data[bytePos+1] = uint8(s and 0xFF)

proc decompressStrip(raw: seq[uint8], compression: uint32,
    expected: int): ImageResult[seq[uint8]] =
  case compression
  of 1:
    if raw.len < expected:
      return err[seq[uint8]](decodingError("tiff: truncated strip"))
    ok(raw[0..<expected])
  of 5:
    let r = decodeLzwTiff(raw, expected)
    if not r.ok: return err[seq[uint8]](r.err)
    if r.value.len < expected:
      return err[seq[uint8]](decodingError("tiff: short LZW strip"))
    ok(r.value[0..<expected])
  of 8, 32946:
    let r = inflateZlib(raw, expected)
    if not r.ok: return err[seq[uint8]](r.err)
    if r.value.len < expected:
      return err[seq[uint8]](decodingError("tiff: short deflate strip"))
    ok(r.value[0..<expected])
  of 32773:
    # PackBits
    var output: seq[uint8] = @[]
    var p = 0
    while p < raw.len and output.len < expected:
      let n = int8(raw[p]); inc(p)
      if n >= 0:
        let k = int(n) + 1
        if p + k > raw.len:
          return err[seq[uint8]](decodingError("tiff: truncated packbits"))
        for i in 0..<k: output.add(raw[p+i])
        p += k
      elif n > -128:
        if p >= raw.len:
          return err[seq[uint8]](decodingError("tiff: truncated packbits run"))
        let k = int(-n) + 1
        for _ in 0..<k: output.add(raw[p])
        inc(p)
    if output.len < expected:
      return err[seq[uint8]](decodingError("tiff: short packbits strip"))
    ok(output[0..<expected])
  of 7, 6, 99:
    err[seq[uint8]](unsupportedError(ukGenericFeature,
      "tiff: JPEG compression not supported"))
  else:
    err[seq[uint8]](unsupportedError(ukGenericFeature,
      "tiff: compression " & $compression))

proc ycbcrToRgb(y, cb, cr: float32, coef: array[3, float32]): tuple[r, g, b: uint8] =
  let cbi = cb - 128.0; let cri = cr - 128.0
  # Using coefficients (default BT.601 0.299/0.587/0.114 style via tiff crate):
  # R = Y + 2*(1-Kr)*Cr etc. Simplified with standard JPEG factors scaled by coef.
  let kr = coef[0]; let kb = coef[2]
  let r = y + 2.0 * (1.0 - kr) * cri
  let b = y + 2.0 * (1.0 - kb) * cbi
  let g = (y - kr * r - kb * b) / coef[1]
  (uint8(clamp(int(r + 0.5), 0, 255)), uint8(clamp(int(g + 0.5), 0, 255)),
    uint8(clamp(int(b + 0.5), 0, 255)))

proc buildChunky(full: seq[uint8], w, h, spp, bitDepth: int, photo: uint32,
    bits: seq[int], predictor: uint32, fillLsb: bool, e: TiffEndian,
    ifd: TiffIfd, data: seq[uint8]): ImageResult[DynamicImage] =
  let isFloat =
    block:
      let (f, v) = ifd.find(339)
      f and v.count > 0 and valU32(v, 0, e) == 3
  proc sampAt(x, y, c: int): uint32 =
    if bitDepth >= 8:
      let bps = bitDepth div 8
      if isFloat:
        let o = (y*w+x)*spp*bps + c*4
        var u: uint32
        if e == teLittle:
          u = uint32(full[o]) or (uint32(full[o+1]) shl 8) or
            (uint32(full[o+2]) shl 16) or (uint32(full[o+3]) shl 24)
        else:
          u = (uint32(full[o]) shl 24) or (uint32(full[o+1]) shl 16) or
            (uint32(full[o+2]) shl 8) or uint32(full[o+3])
        u # bits; converted by caller via cast
      else:
        var v = 0'u32
        let o = (y*w+x)*spp*bps + c*bps
        if e == teLittle:
          for b in 0..<bps: v = v or (uint32(full[o+b]) shl (8*b))
        else:
          for b in 0..<bps: v = (v shl 8) or uint32(full[o+b])
        v
    else:
      let rb = (w * spp * bitDepth + 7) div 8
      let bitpos = (x * spp + c) * bitDepth
      var v = 0'u32
      for k in 0..<bitDepth:
        let bi = bitpos + k
        let bit =
          if not fillLsb: int((full[y*rb + bi div 8] shr uint8(7 - (bi mod 8))) and 1)
          else: int((full[y*rb + bi div 8] shr uint8(bi mod 8)) and 1)
        v = (v shl 1) or uint32(bit)
      v
  let maxv = if bitDepth >= 32: 0xFFFFFFFF'u32 else: (1'u32 shl bitDepth) - 1
  proc to8(v: uint32): uint8 =
    if bitDepth == 8: uint8(v)
    elif bitDepth == 16: uint8((v * 255 + 32768) div 65535)
    elif bitDepth == 32: uint8((v shr 24) and 0xFF)
    else: uint8((v * 255 + maxv div 2) div maxv)
  proc to16(v: uint32): uint16 =
    if bitDepth == 16: uint16(v)
    elif bitDepth == 8: uint16(v) * 257
    else: uint16((v * 65535 + maxv div 2) div maxv)
  case photo
  of 0: # WhiteIsZero -> invert to L
    if spp != 1: return err[DynamicImage](decodingError("tiff: whiteiszero spp"))
    if bitDepth == 16:
      var px = newSeq[Luma[uint16]](w*h)
      for y in 0..<h:
        for x in 0..<w: px[y*w+x] = Luma[uint16](data: [65535'u16 - uint16(sampAt(x,y,0))])
      return ok(DynamicImage(kind: dkLuma16, luma16:
        Gray16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
    else:
      var px = newSeq[Luma[uint8]](w*h)
      for y in 0..<h:
        for x in 0..<w: px[y*w+x] = Luma[uint8](data: [255'u8 - to8(sampAt(x,y,0))])
      return ok(DynamicImage(kind: dkLuma8, luma8:
        GrayImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  of 1: # BlackIsZero
    if spp == 1:
      if isFloat:
        var px = newSeq[Luma[float32]](w*h)
        for y in 0..<h:
          for x in 0..<w: px[y*w+x] = Luma[float32](data: [cast[float32](sampAt(x,y,0))])
        return ok(DynamicImage(kind: dkLuma32F, luma32f:
          Gray32FImage(width: uint32(w), height: uint32(h), pixels: move(px))))
      elif bitDepth == 16:
        var px = newSeq[Luma[uint16]](w*h)
        for y in 0..<h:
          for x in 0..<w: px[y*w+x] = Luma[uint16](data: [uint16(sampAt(x,y,0))])
        return ok(DynamicImage(kind: dkLuma16, luma16:
          Gray16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[Luma[uint8]](w*h)
        for y in 0..<h:
          for x in 0..<w: px[y*w+x] = Luma[uint8](data: [to8(sampAt(x,y,0))])
        return ok(DynamicImage(kind: dkLuma8, luma8:
          GrayImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif spp == 2:
      if bitDepth == 16:
        var px = newSeq[LumaA[uint16]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = LumaA[uint16](data: [uint16(sampAt(x,y,0)), to16(sampAt(x,y,1))])
        return ok(DynamicImage(kind: dkLumaA16, lumaA16:
          GrayAlpha16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[LumaA[uint8]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = LumaA[uint8](data: [to8(sampAt(x,y,0)), to8(uint16(sampAt(x,y,1)))])
        return ok(DynamicImage(kind: dkLumaA8, lumaA8:
          GrayAlphaImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    else:
      return err[DynamicImage](decodingError("tiff: gray spp"))
  of 2: # RGB
    if spp < 3: return err[DynamicImage](decodingError("tiff: rgb spp"))
    let hasAlpha = spp >= 4
    # extra samples: tag 338, 0=unspecified ok, 1=associated alpha (premultiplied - unpremult?)
    if isFloat:
      if hasAlpha:
        var px = newSeq[Rgba[float32]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgba[float32](data: [cast[float32](sampAt(x,y,0)),
              cast[float32](sampAt(x,y,1)), cast[float32](sampAt(x,y,2)),
              cast[float32](sampAt(x,y,3))])
        return ok(DynamicImage(kind: dkRgba32F, rgba32f:
          Rgba32FImage(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[Rgb[float32]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgb[float32](data: [cast[float32](sampAt(x,y,0)),
              cast[float32](sampAt(x,y,1)), cast[float32](sampAt(x,y,2))])
        return ok(DynamicImage(kind: dkRgb32F, rgb32f:
          Rgb32FImage(width: uint32(w), height: uint32(h), pixels: move(px))))
    elif bitDepth == 16:
      if hasAlpha:
        var px = newSeq[Rgba[uint16]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgba[uint16](data: [uint16(sampAt(x,y,0)), uint16(sampAt(x,y,1)),
              uint16(sampAt(x,y,2)), to16(sampAt(x,y,3))])
        return ok(DynamicImage(kind: dkRgba16, rgba16:
          Rgba16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[Rgb[uint16]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgb[uint16](data: [uint16(sampAt(x,y,0)), uint16(sampAt(x,y,1)),
              uint16(sampAt(x,y,2))])
        return ok(DynamicImage(kind: dkRgb16, rgb16:
          Rgb16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
    else:
      if hasAlpha:
        var px = newSeq[Rgba[uint8]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgba[uint8](data: [to8(sampAt(x,y,0)), to8(sampAt(x,y,1)),
              to8(sampAt(x,y,2)), to8(sampAt(x,y,3))])
        return ok(DynamicImage(kind: dkRgba8, rgba8:
          RgbaImage(width: uint32(w), height: uint32(h), pixels: move(px))))
      else:
        var px = newSeq[Rgb[uint8]](w*h)
        for y in 0..<h:
          for x in 0..<w:
            px[y*w+x] = Rgb[uint8](data: [to8(sampAt(x,y,0)), to8(sampAt(x,y,1)),
              to8(sampAt(x,y,2))])
        return ok(DynamicImage(kind: dkRgb8, rgb8:
          RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  of 3: # Palette
    if spp != 1: return err[DynamicImage](decodingError("tiff: palette spp"))
    let (fMap, vMap) = ifd.find(320)
    if not fMap: return err[DynamicImage](decodingError("tiff: missing colormap"))
    let n = 1 shl bitDepth
    if int(vMap.count) < 3 * n:
      return err[DynamicImage](decodingError("tiff: short colormap"))
    var pal = newSeq[tuple[r, g, b: uint8]](n)
    for i in 0..<n:
      pal[i] = (uint8(valU16(vMap, i, e) div 257),
        uint8(valU16(vMap, n+i, e) div 257), uint8(valU16(vMap, 2*n+i, e) div 257))
    var px = newSeq[Rgb[uint8]](w*h)
    for y in 0..<h:
      for x in 0..<w:
        let v = int(sampAt(x, y, 0))
        if v >= n: return err[DynamicImage](decodingError("tiff: cmap index OOB"))
        px[y*w+x] = Rgb[uint8](data: [pal[v].r, pal[v].g, pal[v].b])
    return ok(DynamicImage(kind: dkRgb8, rgb8:
      RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  of 5: # CMYK -> RGB naive
    if spp < 4: return err[DynamicImage](decodingError("tiff: cmyk spp"))
    if bitDepth == 16:
      var px = newSeq[Rgb[uint16]](w*h)
      for y in 0..<h:
        for x in 0..<w:
          let c = uint32(sampAt(x,y,0)); let m = uint32(sampAt(x,y,1))
          let yy = uint32(sampAt(x,y,2)); let k = uint32(sampAt(x,y,3))
          px[y*w+x] = Rgb[uint16](data: [
            uint16(65535 - min(65535'u32, c + k)),
            uint16(65535 - min(65535'u32, m + k)),
            uint16(65535 - min(65535'u32, yy + k))])
      return ok(DynamicImage(kind: dkRgb16, rgb16:
        Rgb16Image(width: uint32(w), height: uint32(h), pixels: move(px))))
    else:
      var px = newSeq[Rgb[uint8]](w*h)
      for y in 0..<h:
        for x in 0..<w:
          let c = to8(sampAt(x,y,0)); let m = to8(sampAt(x,y,1))
          let yy = to8(sampAt(x,y,2)); let k = to8(sampAt(x,y,3))
          px[y*w+x] = Rgb[uint8](data: [
            255'u8 - min(255'u8, uint8(min(255, int(c)+int(k)))),
            255'u8 - min(255'u8, uint8(min(255, int(m)+int(k)))),
            255'u8 - min(255'u8, uint8(min(255, int(yy)+int(k))))])
      return ok(DynamicImage(kind: dkRgb8, rgb8:
        RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  of 6: # YCbCr
    if spp < 3: return err[DynamicImage](decodingError("tiff: ycbcr spp"))
    let sub = getArray(ifd, 530, e, 2, 0)
    var sh, sv = 1
    if sub.len >= 2 and sub[0] != 0 and sub[1] != 0:
      sh = int(sub[0]); sv = int(sub[1])
    else:
      sh = 2; sv = 2
    if sh notin [1, 2] or sv notin [1, 2]:
      return err[DynamicImage](unsupportedError(ukGenericFeature, "tiff: ycbcr subsampling"))
    var coef = [0.299'f32, 0.587'f32, 0.114'f32]
    let (fC, vC) = ifd.find(529)
    if fC and vC.count >= 3 and vC.typ == 5:
      for i in 0..2:
        let o = i * 8
        let num = int32(rd32(vC.data, o, e)); let den = int32(rd32(vC.data, o+4, e))
        if den != 0: coef[i] = float32(num) / float32(den)
    var px = newSeq[Rgb[uint8]](w*h)
    for y in 0..<h:
      for x in 0..<w:
        let sx = x div sh * sh; let sy = y div sv * sv
        let Y = float32(sampAt(x, y, 0))
        let Cb = float32(sampAt(sx, sy, 1))
        let Cr = float32(sampAt(sx, sy, 2))
        let (r, g, b) = ycbcrToRgb(Y, Cb, Cr, coef)
        px[y*w+x] = Rgb[uint8](data: [r, g, b])
    return ok(DynamicImage(kind: dkRgb8, rgb8:
      RgbImage(width: uint32(w), height: uint32(h), pixels: move(px))))
  else:
    return err[DynamicImage](unsupportedError(ukColor, "tiff: photometric " & $photo))

proc decodeIfd(data: seq[uint8], ifd: TiffIfd,
    e: TiffEndian): ImageResult[DynamicImage] =
  let w = int(getU32(ifd, 256, e, 0))
  let h = int(getU32(ifd, 257, e, 0))
  if w == 0 or h == 0:
    return err[DynamicImage](decodingError("tiff: bad dimensions"))
  if w > 1 shl 24 or h > 1 shl 24:
    return err[DynamicImage](limitError(lkDimensionError, "tiff: dimensions too large"))
  let bps = getArray(ifd, 258, e, 6, 1)
  let compression = getU32(ifd, TCompression, e, 1)
  let photo = getU32(ifd, TPhotometric, e, 0xFFFF)
  let spp = int(getU32(ifd, 277, e, 1))
  let planar = getU32(ifd, 284, e, 1)
  let predictor = getU32(ifd, 317, e, 1)
  let fillOrder = getU32(ifd, 266, e, 1)
  if fillOrder != 1 and fillOrder != 2:
    return err[DynamicImage](decodingError("tiff: bad fill order"))
  let fillLsb = fillOrder == 2
  if planar != 1 and planar != 2:
    return err[DynamicImage](decodingError("tiff: bad planar config"))
  # bits per sample (only first spp matter)
  var bits = newSeq[int](spp)
  for i in 0..<spp: bits[i] = int(bps[i])
  let bitDepth = bits[0]
  for b in bits:
    if b != bitDepth:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "tiff: mixed bit depths"))
  if bitDepth notin [1, 2, 4, 8, 16, 32]:
    return err[DynamicImage](unsupportedError(ukColor,
      "tiff: bit depth " & $bitDepth))
  # sample format: 1=uint default, 3=float
  let (sfFound, sfVal) = ifd.find(339)
  var sampleFormat = 1'u32
  if sfFound and sfVal.count > 0: sampleFormat = valU32(sfVal, 0, e)
  let isFloat = sampleFormat == 3
  if isFloat and bitDepth != 32:
    return err[DynamicImage](unsupportedError(ukColor, "tiff: float bit depth"))
  if not isFloat and sampleFormat != 1 and sampleFormat != 2:
    return err[DynamicImage](unsupportedError(ukGenericFeature, "tiff: sample format"))
  # strips vs tiles
  let (hasTiles, _) = ifd.find(TTileWidth)
  let tiled = hasTiles
  type Chunk = tuple[off, byteCount: int]
  var chunks: seq[Chunk] = @[]
  var rowsPerChunk = h
  var chunkWidths: seq[int] = @[]
  var chunkHeights: seq[int] = @[]
  if not tiled:
    let offsets = getArray(ifd, TStripOffsets, e, 1, 0)
    let counts = getArray(ifd, TStripByteCounts, e, 1, 0)
    let fOff = ifd.find(TStripOffsets)
    let fCnt = ifd.find(TStripByteCounts)
    if not fOff.found or not fCnt.found:
      return err[DynamicImage](decodingError("tiff: missing strip tags"))
    let n = max(fOff.v.count, fCnt.v.count)
    rowsPerChunk = int(getU32(ifd, TRowsPerStrip, e, uint32(h)))
    if rowsPerChunk == 0:
      return err[DynamicImage](decodingError("tiff: bad rows per strip"))
    chunks = newSeq[Chunk](int(n))
    for i in 0..<int(n):
      let o = if i < offsets.len: int(offsets[i]) else: int(offsets[^1])
      let c = if i < counts.len: int(counts[i]) else: int(counts[^1])
      chunks[i] = (o, c)
  else:
    if planar == 2:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "tiff: planar tiled"))
    let tw = int(getU32(ifd, TTileWidth, e, 0))
    let tl = int(getU32(ifd, TTileLength, e, 0))
    if tw == 0 or tl == 0:
      return err[DynamicImage](decodingError("tiff: bad tile size"))
    let fOff = ifd.find(TTileOffsets)
    let fCnt = ifd.find(TTileByteCounts)
    if not fOff.found or not fCnt.found:
      return err[DynamicImage](decodingError("tiff: missing tile tags"))
    let offsets = getArray(ifd, TTileOffsets, e, 1, 0)
    let counts = getArray(ifd, TTileByteCounts, e, 1, 0)
    let n = max(int(fOff.v.count), int(fCnt.v.count))
    let tilesAcross = (w + tw - 1) div tw
    chunks = newSeq[Chunk](n)
    chunkWidths = newSeq[int](n)
    chunkHeights = newSeq[int](n)
    for i in 0..<n:
      let tx = i mod tilesAcross; let ty = i div tilesAcross
      chunkWidths[i] = min(tw, w - tx * tw)
      chunkHeights[i] = min(tl, h - ty * tl)
      let o = if i < offsets.len: int(offsets[i]) else: int(offsets[^1])
      let c = if i < counts.len: int(counts[i]) else: int(counts[^1])
      chunks[i] = (o, c)
    rowsPerChunk = tl
  # decode chunk bytes -> full sample plane(s)
  let bytesPerSample = if isFloat: 4 elif bitDepth >= 8: bitDepth div 8 else: 0
  proc planeExpected(cw, chh: int): int =
    if bitDepth >= 8: cw * chh * spp * bytesPerSample
    else: ((cw * spp * bitDepth + 7) div 8) * chh
  # For planar==2 chunky logic differs: chunks split per plane.
  if planar == 2:
    if tiled:
      return err[DynamicImage](unsupportedError(ukGenericFeature, "tiff: planar tiled"))
    let nStrips = chunks.len
    if nStrips mod spp != 0:
      return err[DynamicImage](decodingError("tiff: planar strip count"))
    let stripsPerPlane = nStrips div spp
    var planes = newSeq[seq[uint8]](spp)
    for pl in 0..<spp: planes[pl] = newSeq[uint8](w * h * (if bitDepth >= 8: bytesPerSample else: 1))
    for pl in 0..<spp:
      var y = 0
      for s in 0..<stripsPerPlane:
        let (off, cnt) = chunks[pl * stripsPerPlane + s]
        if off + cnt > data.len:
          return err[DynamicImage](decodingError("tiff: strip OOB"))
        let rows = min(rowsPerChunk, h - y)
        let exp = planeExpected(w, rows) div spp
        let dr = decompressStrip(data[off..<off+cnt], compression, exp)
        if not dr.ok: return err[DynamicImage](dr.err)
        var blk = dr.value
        if predictor == 2: undoPredictor(blk, w, 1, bitDepth)
        if bitDepth >= 8:
          for i in 0..<w*rows*bytesPerSample:
            planes[pl][(y*w)*bytesPerSample+i] = blk[i]
        else:
          # bit-packed single plane: copy row bytes
          let rb = (w * bitDepth + 7) div 8
          for r in 0..<rows:
            for i in 0..<rb: planes[pl][(y+r)*rb+i] = blk[r*rb+i]
        y += rows
    # interleave planes into chunky buffer then fall through via samples getter
    if bitDepth >= 8 and not isFloat:
      var chunky = newSeq[uint8](w * h * spp * bytesPerSample)
      for y in 0..<h:
        for x in 0..<w:
          for c in 0..<spp:
            for b in 0..<bytesPerSample:
              chunky[(y*w+x)*spp*bytesPerSample + c*bytesPerSample + b] =
                planes[c][(y*w+x)*bytesPerSample + b]
      # build via chunky path below: stash into single-strip structure
      return buildChunky(chunky, w, h, spp, bitDepth, photo, bits, predictor,
        fillLsb, e, ifd, data)
    else:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "tiff: planar narrow/float"))
  # chunky: assemble full buffer
  var full = newSeq[uint8](planeExpected(w, h))
  if not tiled:
    var y = 0
    for (off, cnt) in chunks:
      if off + cnt > data.len:
        return err[DynamicImage](decodingError("tiff: strip OOB"))
      let rows = min(rowsPerChunk, h - y)
      let exp = planeExpected(w, rows)
      let dr = decompressStrip(data[off..<off+cnt], compression, exp)
      if not dr.ok: return err[DynamicImage](dr.err)
      var blk = dr.value
      if predictor == 2: undoPredictor(blk, w, spp, bitDepth)
      let rb = if bitDepth >= 8: w * spp * bytesPerSample
               else: (w * spp * bitDepth + 7) div 8
      for r in 0..<rows:
        for i in 0..<rb: full[(y+r)*rb+i] = blk[r*rb+i]
      y += rows
  else:
    let tw = int(getU32(ifd, TTileWidth, e, 0))
    let tilesAcross = (w + tw - 1) div tw
    for ti, (off, cnt) in chunks:
      if off + cnt > data.len:
        return err[DynamicImage](decodingError("tiff: tile OOB"))
      let tx = ti mod tilesAcross; let ty = ti div tilesAcross
      let cw = chunkWidths[ti]; let chh = chunkHeights[ti]
      let exp = planeExpected(cw, chh)
      let dr = decompressStrip(data[off..<off+cnt], compression, exp)
      if not dr.ok: return err[DynamicImage](dr.err)
      var blk = dr.value
      if predictor == 2: undoPredictor(blk, cw, spp, bitDepth)
      if bitDepth >= 8:
        let rb = cw * spp * bytesPerSample
        for r in 0..<chh:
          for x in 0..<cw:
            for c in 0..<spp:
              for b in 0..<bytesPerSample:
                full[((ty*rowsPerChunk+r)*w + tx*tw+x)*spp*bytesPerSample + c*bytesPerSample+b] =
                  blk[r*rb + x*spp*bytesPerSample + c*bytesPerSample+b]
      else:
        # sub-byte tiles: unpack then place
        for r in 0..<chh:
          let srcRb = (cw * spp * bitDepth + 7) div 8
          let dstRb = (w * spp * bitDepth + 7) div 8
          var rowSamp = unpackBits(blk[r*srcRb..<r*srcRb+srcRb],
            cw * spp, bitDepth, fillLsb)
          for x in 0..<cw*spp:
            let dstBit = (ty*rowsPerChunk+r)*w*spp + tx*tw*spp + x
            # need full[] as packed bits: write bit
            let byteIdx = (ty*rowsPerChunk+r)*dstRb + dstBit div 8
            let bitInByte = 7 - (dstBit mod 8)
            if rowSamp[x] != 0:
              full[byteIdx] = full[byteIdx] or uint8(1 shl bitInByte)
  return buildChunky(full, w, h, spp, bitDepth, photo, bits, predictor,
    fillLsb, e, ifd, data)

proc decodeTiffAll*(data: seq[uint8]): ImageResult[seq[DynamicImage]] =
  if data.len < 8:
    return err[seq[DynamicImage]](decodingError("tiff: too short"))
  var e = teLittle
  if data[0] == uint8('I') and data[1] == uint8('I'): e = teLittle
  elif data[0] == uint8('M') and data[1] == uint8('M'): e = teBig
  else: return err[seq[DynamicImage]](decodingError("tiff: bad byte order"))
  if rd16(data, 2, e) != 42:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "tiff: not classic TIFF"))
  var off = int(rd32(data, 4, e))
  var pages: seq[DynamicImage] = @[]
  var guard = 0
  while off != 0:
    inc guard
    if guard > 64: break
    if off + 2 > data.len:
      return err[seq[DynamicImage]](decodingError("tiff: IFD offset OOB"))
    let ir = parseIfd(data, off, e)
    if not ir.ok: return err[seq[DynamicImage]](ir.err)
    let dr = decodeIfd(data, ir.value, e)
    if not dr.ok: return err[seq[DynamicImage]](dr.err)
    pages.add(dr.value)
    off = int(ir.value.nextOff)
  if pages.len == 0:
    return err[seq[DynamicImage]](decodingError("tiff: no images"))
  ok(pages)

proc decodeTiff*(data: seq[uint8]): ImageResult[DynamicImage] =
  let r = decodeTiffAll(data)
  if not r.ok: return err[DynamicImage](r.err)
  ok(r.value[0])

proc putU16(dst: var seq[uint8], e: TiffEndian, v: uint16) =
  if e == teLittle: dst.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF)])
  else: dst.add([uint8((v shr 8) and 0xFF), uint8(v and 0xFF)])

proc putU32(dst: var seq[uint8], e: TiffEndian, v: uint32) =
  if e == teLittle:
    dst.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF),
      uint8((v shr 16) and 0xFF), uint8((v shr 24) and 0xFF)])
  else:
    dst.add([uint8((v shr 24) and 0xFF), uint8((v shr 16) and 0xFF),
      uint8((v shr 8) and 0xFF), uint8(v and 0xFF)])

proc addEntry(entries: var seq[uint8], e: TiffEndian, tag, typ: uint16,
    count: uint32, val: uint32) =
  putU16(entries, e, tag); putU16(entries, e, typ)
  putU32(entries, e, count); putU32(entries, e, val)

proc encodeTiff*(img: DynamicImage): ImageResult[seq[uint8]] =
  ## Baseline writer: little-endian, single strip, compression None, chunky.
  var spp = 0; var bps = 8; var photo = 2'u32
  var w, h: int
  var raw: seq[uint8]
  case img.kind
  of dkLuma8:
    (spp, photo) = (1, 1'u32)
    w = int(img.luma8.width); h = int(img.luma8.height)
    raw = newSeq[uint8](w*h)
    for i, p in img.luma8.pixels: raw[i] = p.data[0]
  of dkRgb8:
    (spp, photo) = (3, 2'u32)
    w = int(img.rgb8.width); h = int(img.rgb8.height)
    raw = newSeq[uint8](w*h*3)
    for i, p in img.rgb8.pixels:
      raw[3*i]=p.data[0]; raw[3*i+1]=p.data[1]; raw[3*i+2]=p.data[2]
  of dkRgba8:
    (spp, photo) = (4, 2'u32)
    w = int(img.rgba8.width); h = int(img.rgba8.height)
    raw = newSeq[uint8](w*h*4)
    for i, p in img.rgba8.pixels:
      raw[4*i]=p.data[0]; raw[4*i+1]=p.data[1]
      raw[4*i+2]=p.data[2]; raw[4*i+3]=p.data[3]
  of dkLuma16:
    (spp, photo) = (1, 1'u32); bps = 16
    w = int(img.luma16.width); h = int(img.luma16.height)
    raw = newSeq[uint8](w*h*2)
    for i, p in img.luma16.pixels:
      raw[2*i]=uint8(p.data[0] and 0xFF); raw[2*i+1]=uint8((p.data[0] shr 8) and 0xFF)
  of dkRgb16:
    (spp, photo) = (3, 2'u32); bps = 16
    w = int(img.rgb16.width); h = int(img.rgb16.height)
    raw = newSeq[uint8](w*h*6)
    for i, p in img.rgb16.pixels:
      for c in 0..2:
        raw[6*i+2*c]=uint8(p.data[c] and 0xFF); raw[6*i+2*c+1]=uint8((p.data[c] shr 8) and 0xFF)
  else:
    return err[seq[uint8]](unsupportedError(ukColor, "tiff: encode this variant first"))
  let e = teLittle
  # layout: header(8) + ifd(count + 12*n + next) + bps array + data
  let nEntries = 11
  let ifdOff = 8
  let ifdLen = 2 + 12 * nEntries + 4
  let bpsOff = ifdOff + ifdLen
  let dataOff = bpsOff + (if spp > 2: spp * 2 else: 0)
  var output = @[uint8('I'), uint8('I'), 42, 0, 8, 0, 0, 0]
  var entries: seq[uint8] = @[]
  putU16(entries, e, uint16(nEntries))
  addEntry(entries, e, 256, 4, 1, uint32(w))
  addEntry(entries, e, 257, 4, 1, uint32(h))
  if spp <= 2:
    addEntry(entries, e, 258, 3, uint32(spp), uint32(bps) or (uint32(bps) shl 16))
  else:
    addEntry(entries, e, 258, 3, uint32(spp), uint32(bpsOff))
  addEntry(entries, e, 259, 3, 1, 1)
  addEntry(entries, e, 262, 3, 1, uint16(photo))
  addEntry(entries, e, 273, 4, 1, uint32(dataOff))
  addEntry(entries, e, 277, 3, 1, uint16(spp))
  addEntry(entries, e, 278, 4, 1, uint32(h))
  addEntry(entries, e, 279, 4, 1, uint32(raw.len))
  addEntry(entries, e, 284, 3, 1, 1)
  addEntry(entries, e, 339, 3, 1, 1)
  for b in entries: output.add(b)
  putU32(output, e, 0) # next IFD
  if spp > 2:
    for _ in 0..<spp: putU16(output, e, uint16(bps))
  for b in raw: output.add(b)
  ok(output)
