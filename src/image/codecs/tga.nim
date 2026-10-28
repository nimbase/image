## TGA codec — references/image/src/codecs/tga/ (decoder 462, encoder 534, header 175)
import ../color
import ../error
import ../buffer
import ../dynamic

type
  TgaHeader* = object
    idLen*, mapType*, imgType*: uint8
    mapOrigin*, mapLen*: uint16
    mapEntrySize*: uint8
    xOrigin*, yOrigin*: uint16
    width*, height*: uint16
    pixelDepth*: uint8
    imgDesc*: uint8

func imgTypeIsColorMapped(t: uint8): bool = t == 1 or t == 9
func imgTypeIsEncoded(t: uint8): bool = t == 9 or t == 10 or t == 11
func imgTypeIsColor(t: uint8): bool = t in {1'u8, 2, 9, 10}

func expandRgb15toRgb24(lo, hi: uint8): tuple[r, g, b: uint8] =
  let v = uint16(lo) or (uint16(hi) shl 8)
  template unorm5(x: uint16): uint8 = uint8((x * 2108 + 92) shr 8)
  (unorm5(v and 31), unorm5((v shr 5) and 31), unorm5((v shr 10) and 31))

proc parseTgaHeader(data: openArray[uint8]): ImageResult[TgaHeader] =
  if data.len < 18:
    return err[TgaHeader](decodingError("tga: too short"))
  ok(TgaHeader(
    idLen: data[0], mapType: data[1], imgType: data[2],
    mapOrigin: uint16(data[3]) or (uint16(data[4]) shl 8),
    mapLen: uint16(data[5]) or (uint16(data[6]) shl 8),
    mapEntrySize: data[7],
    xOrigin: uint16(data[8]) or (uint16(data[9]) shl 8),
    yOrigin: uint16(data[10]) or (uint16(data[11]) shl 8),
    width: uint16(data[12]) or (uint16(data[13]) shl 8),
    height: uint16(data[14]) or (uint16(data[15]) shl 8),
    pixelDepth: data[16], imgDesc: data[17]))

proc decodeTga*(data: seq[uint8]): ImageResult[DynamicImage] =
  let hr = parseTgaHeader(data)
  if not hr.ok: return err[DynamicImage](hr.err)
  let h = hr.value
  if h.width == 0 or h.height == 0:
    return err[DynamicImage](decodingError("tga: empty image"))
  if h.imgType == 0:
    return err[DynamicImage](decodingError("tga: no image data"))
  if h.imgType notin [1'u8, 2, 3, 9, 10, 11]:
    return err[DynamicImage](unsupportedError(ukGenericFeature, "tga: unknown image type"))
  if imgTypeIsColorMapped(h.imgType) and h.mapType != 1:
    return err[DynamicImage](decodingError("tga: colormap type must be 1"))
  let w = int(h.width); let hh = int(h.height)
  let n = w * hh
  let rawBpp = (int(h.pixelDepth) + 7) div 8
  let numAttribBits = int(h.imgDesc and 0x0F)
  let totalBits = if imgTypeIsColorMapped(h.imgType): int(h.mapEntrySize)
                  else: int(h.pixelDepth)
  let numOtherBits = totalBits - numAttribBits
  if numOtherBits < 0:
    return err[DynamicImage](decodingError("tga: more alpha bits than pixel bits"))
  var colorType = ctRgb8
  var isGray = false
  var alphaOnlyAsLuma = false
  var isRgb5x1 = false
  if imgTypeIsColor(h.imgType):
    if (numAttribBits == 0 and numOtherBits == 32) or
        (numAttribBits == 8 and numOtherBits == 24):
      colorType = ctRgba8
    elif numAttribBits == 0 and numOtherBits == 24:
      colorType = ctRgb8
    elif (numAttribBits == 1 and numOtherBits == 15) or
        (numAttribBits == 0 and numOtherBits == 15) or
        (numAttribBits == 0 and numOtherBits == 16):
      colorType = ctRgb8; isRgb5x1 = true
    else:
      return err[DynamicImage](unsupportedError(ukColor, "tga: unsupported color depth"))
  else:
    if numAttribBits == 8 and numOtherBits == 8: colorType = ctLa8
    elif numAttribBits == 0 and numOtherBits == 8: colorType = ctL8
    elif numAttribBits == 8 and numOtherBits == 0:
      colorType = ctL8; alphaOnlyAsLuma = true
    else:
      return err[DynamicImage](unsupportedError(ukColor, "tga: unsupported gray depth"))
    isGray = true
  var pos = 18 + int(h.idLen)
  # colormap
  var cmapBytes: seq[uint8] = @[]
  var cmapEntrySize = 0
  var cmapStart = 0
  if h.mapType == 1:
    if h.mapEntrySize notin [15'u8, 16, 24, 32]:
      return err[DynamicImage](unsupportedError(ukGenericFeature, "tga: bad cmap entry size"))
    cmapEntrySize = (int(h.mapEntrySize) + 7) div 8
    let cmapLen = cmapEntrySize * int(h.mapLen)
    if pos + cmapLen > data.len:
      return err[DynamicImage](decodingError("tga: truncated colormap"))
    cmapBytes = data[pos..<pos+cmapLen]
    cmapStart = int(h.mapOrigin)
    pos += cmapLen
    if imgTypeIsColorMapped(h.imgType) and h.mapEntrySize in [15'u8, 16]:
      # pre-expand 15-bit entries to 24-bit
      var expanded = newSeq[uint8]((cmapBytes.len div 2) * 3)
      var o = 0
      var i = 0
      while i + 1 < cmapBytes.len:
        let (r, g, b) = expandRgb15toRgb24(cmapBytes[i], cmapBytes[i+1])
        expanded[o] = r; expanded[o+1] = g; expanded[o+2] = b
        o += 3; i += 2
      cmapBytes = expanded
      cmapEntrySize = 3
  # raw pixel bytes (indices or direct)
  let outBpp = int(colorType.bytesPerPixel())
  var raw = newSeq[uint8](n * rawBpp)
  if imgTypeIsEncoded(h.imgType):
    var idx = 0
    while idx < raw.len:
      if pos >= data.len:
        return err[DynamicImage](decodingError("tga: truncated RLE"))
      let pkt = data[pos]; inc pos
      if (pkt and 0x80) != 0:
        let count = int(pkt and 0x7F) + 1
        if pos + rawBpp > data.len:
          return err[DynamicImage](decodingError("tga: truncated RLE repeat"))
        for _ in 0..<count:
          if idx + rawBpp > raw.len: break
          for k in 0..<rawBpp: raw[idx+k] = data[pos+k]
          idx += rawBpp
        pos += rawBpp
      else:
        let count = int(pkt) + 1
        let bytes = count * rawBpp
        let take = min(bytes, raw.len - idx)
        if pos + take > data.len:
          return err[DynamicImage](decodingError("tga: truncated RLE raw"))
        for k in 0..<take: raw[idx+k] = data[pos+k]
        pos += take
        idx += take
  else:
    if pos + raw.len > data.len:
      return err[DynamicImage](decodingError("tga: truncated"))
    for i in 0..<raw.len: raw[i] = data[pos+i]
  # orientation fixup on raw (before cmap expand)
  let topOrigin = (h.imgDesc and 0x20) != 0
  let rightOrigin = (h.imgDesc and 0x10) != 0
  if not topOrigin and hh > 1:
    let stride = w * rawBpp
    for y in 0..<hh div 2:
      for k in 0..<stride:
        let a = y * stride + k
        let b = (hh - 1 - y) * stride + k
        swap(raw[a], raw[b])
  if rightOrigin and w > 1:
    for y in 0..<hh:
      for x in 0..<w div 2:
        for k in 0..<rawBpp:
          let a = y * w * rawBpp + x * rawBpp + k
          let b = y * w * rawBpp + (w - 1 - x) * rawBpp + k
          swap(raw[a], raw[b])
  # expand to output
  if imgTypeIsColorMapped(h.imgType):
    if rawBpp > 2:
      return err[DynamicImage](unsupportedError(ukGenericFeature, "tga: wide cmap index"))
    var outBytes = newSeq[uint8](n * cmapEntrySize)
    if rawBpp == 1:
      for i in 0..<n:
        let index = int(raw[i]) - cmapStart
        if index < 0 or (index+1) * cmapEntrySize > cmapBytes.len:
          return err[DynamicImage](decodingError("tga: bad cmap index"))
        for k in 0..<cmapEntrySize:
          outBytes[i*cmapEntrySize+k] = cmapBytes[index*cmapEntrySize+k]
    else:
      for i in 0..<n:
        let index = int(uint16(raw[2*i]) or (uint16(raw[2*i+1]) shl 8)) - cmapStart
        if index < 0 or (index+1) * cmapEntrySize > cmapBytes.len:
          return err[DynamicImage](decodingError("tga: bad cmap index"))
        for k in 0..<cmapEntrySize:
          outBytes[i*cmapEntrySize+k] = cmapBytes[index*cmapEntrySize+k]
    # cmap entries stored BGR(A); swap to RGB(A)
    if cmapEntrySize == 3:
      for i in 0..<n: swap(outBytes[3*i], outBytes[3*i+2])
    elif cmapEntrySize == 4:
      for i in 0..<n: swap(outBytes[4*i], outBytes[4*i+2])
    if cmapEntrySize == 3:
      var px = newSeq[Rgb[uint8]](n)
      for i in 0..<n: px[i] = Rgb[uint8](data: [outBytes[3*i], outBytes[3*i+1], outBytes[3*i+2]])
      return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: h.width, height: h.height, pixels: move(px))))
    elif cmapEntrySize == 4:
      var px = newSeq[Rgba[uint8]](n)
      for i in 0..<n: px[i] = Rgba[uint8](data: [outBytes[4*i], outBytes[4*i+1], outBytes[4*i+2], outBytes[4*i+3]])
      return ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: h.width, height: h.height, pixels: move(px))))
    else:
      return err[DynamicImage](unsupportedError(ukGenericFeature, "tga: cmap output depth"))
  elif isRgb5x1 and not isGray:
    var px = newSeq[Rgb[uint8]](n)
    for i in 0..<n:
      let (r, g, b) = expandRgb15toRgb24(raw[2*i], raw[2*i+1])
      # 15-bit stored BGR order; expand returns (b-ish?) — reference expands LE u16 as-is then BGR swap later.
      # expand_rgb15 gives [b,g,r]-ordered? Actually bits: val&31 first. Reference then swaps B/R.
      px[i] = Rgb[uint8](data: [b, g, r])
    # BGR->RGB already handled by swap above (we swapped raw LE bytes? no). Apply B/R swap:
    for i in 0..<n: swap(px[i].data[0], px[i].data[2])
    return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: h.width, height: h.height, pixels: move(px))))
  else:
    # direct; BGR->RGB swap for color
    if colorType == ctRgb8:
      for i in 0..<n: swap(raw[3*i], raw[3*i+2])
      var px = newSeq[Rgb[uint8]](n)
      for i in 0..<n: px[i] = Rgb[uint8](data: [raw[3*i], raw[3*i+1], raw[3*i+2]])
      return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: h.width, height: h.height, pixels: move(px))))
    elif colorType == ctRgba8:
      for i in 0..<n: swap(raw[4*i], raw[4*i+2])
      var px = newSeq[Rgba[uint8]](n)
      for i in 0..<n: px[i] = Rgba[uint8](data: [raw[4*i], raw[4*i+1], raw[4*i+2], raw[4*i+3]])
      return ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: h.width, height: h.height, pixels: move(px))))
    elif colorType == ctL8:
      var px = newSeq[Luma[uint8]](n)
      if alphaOnlyAsLuma:
        # raw is alpha-only? reference treats as L8 with raw bytes; take as-is
        for i in 0..<n: px[i] = Luma[uint8](data: [raw[i]])
      else:
        for i in 0..<n: px[i] = Luma[uint8](data: [raw[i]])
      return ok(DynamicImage(kind: dkLuma8, luma8: GrayImage(width: h.width, height: h.height, pixels: move(px))))
    elif colorType == ctLa8:
      var px = newSeq[LumaA[uint8]](n)
      for i in 0..<n: px[i] = LumaA[uint8](data: [raw[2*i], raw[2*i+1]])
      return ok(DynamicImage(kind: dkLumaA8, lumaA8: GrayAlphaImage(width: h.width, height: h.height, pixels: move(px))))
  err[DynamicImage](unsupportedError(ukColor, "tga: unsupported output"))

proc encodeTgaRgb8*(img: RgbImage): seq[uint8] =
  result = newSeq[uint8](18 + img.pixels.len * 3)
  result[2] = 2
  result[12] = uint8(img.width and 0xFF); result[13] = uint8((img.width shr 8) and 0xFF)
  result[14] = uint8(img.height and 0xFF); result[15] = uint8((img.height shr 8) and 0xFF)
  result[16] = 24
  result[17] = 0x20
  var off = 18
  for p in img.pixels:
    result[off] = p.data[2]; result[off+1] = p.data[1]; result[off+2] = p.data[0]
    off += 3

proc encodeTgaRgba8*(img: RgbaImage): seq[uint8] =
  result = newSeq[uint8](18 + img.pixels.len * 4)
  result[2] = 2
  result[12] = uint8(img.width and 0xFF); result[13] = uint8((img.width shr 8) and 0xFF)
  result[14] = uint8(img.height and 0xFF); result[15] = uint8((img.height shr 8) and 0xFF)
  result[16] = 32
  result[17] = 0x28
  var off = 18
  for p in img.pixels:
    result[off] = p.data[2]; result[off+1] = p.data[1]; result[off+2] = p.data[0]; result[off+3] = p.data[3]
    off += 4
