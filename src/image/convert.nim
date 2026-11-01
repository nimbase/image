## Any-format → WebP converter (plan 13).
## `decodeImage` sniffs magic bytes and decodes any supported format to a
## `DynamicImage`; `convertToWebp` / fluent `WebpRequest` re-encode as WebP.
## Animated GIF / multi-page TIFF / multi-image ICO: first frame only.
## 16-bit / float32 sources auto-downconvert to 8-bit (never blank output).
import std/options
import ./color
import ./error
import ./buffer
import ./format
import ./dynamic
import ./reader
import ./math
import ./codecs/farbfeld
import ./codecs/qoi
import ./codecs/pnm
import ./codecs/tga
import ./codecs/hdr
import ./codecs/bmp
import ./codecs/gif
import ./codecs/png
import ./codecs/tiff
import ./codecs/ico
import ./codecs/jpeg
import ./codecs/openexr
import ./codecs/webp
import ./codecs/avif
import ./codecs/heif/heif

const WebpMaxDim* = 16384
  ## VP8L header stores width-1 / height-1 in 14 bits.

proc decodeImage*(data: seq[uint8]): ImageResult[DynamicImage] =
  ## Decode any supported format (magic-byte sniffed) to a DynamicImage.
  ## First frame wins for animated / multi-image inputs. Clean errors,
  ## never raises.
  if data.len == 0:
    return err[DynamicImage](decodingError("convert: empty input"))
  let (found, fmt) = guessFormat(data)
  if not found:
    return err[DynamicImage](unsupportedError(ukFormat,
      "convert: unknown image format"))
  case fmt
  of fmtPng: decodePng(data)
  of fmtJpeg: decodeJpeg(data)
  of fmtBmp: decodeBmp(data)
  of fmtTiff: decodeTiff(data)
  of fmtTga: decodeTga(data)
  of fmtPnm: decodePnm(data)
  of fmtIco: decodeIco(data)
  of fmtWebP: decodeWebp(data)
  of fmtHeif: decodeHeif(data)
  of fmtAvif: decodeAvif(data) # v1 stub: returns Unsupported, propagates
  of fmtOpenExr: decodeExr(data)
  of fmtGif:
    let g = decodeGif(data)
    if not g.ok: return err[DynamicImage](g.err)
    if g.value.frames.len == 0:
      return err[DynamicImage](decodingError("gif: no frames"))
    let fr = gifFrameToRgba(g.value, 0)
    if not fr.ok: return err[DynamicImage](fr.err)
    # composite frame 0 over a transparent full-canvas buffer
    let cw = int(g.value.width); let ch = int(g.value.height)
    let fw = int(fr.value.width); let fh = int(fr.value.height)
    let ox = min(int(g.value.frames[0].left), cw)
    let oy = min(int(g.value.frames[0].top), ch)
    var px = newSeq[Rgba[uint8]](cw * ch)
    for y in 0..<fh:
      if oy + y >= ch: break
      for x in 0..<fw:
        if ox + x >= cw: break
        px[(oy + y) * cw + (ox + x)] = fr.value.pixels[y * fw + x]
    ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(
      width: uint32(cw), height: uint32(ch), pixels: move(px))))
  of fmtQoi:
    let r = decodeQoi(data)
    if not r.ok: return err[DynamicImage](r.err)
    ok(DynamicImage(kind: dkRgba8, rgba8: r.value))
  of fmtHdr:
    let r = decodeHdr(data)
    if not r.ok: return err[DynamicImage](r.err)
    ok(DynamicImage(kind: dkRgb32F, rgb32f: r.value))
  of fmtFarbfeld:
    let r = decodeFarbfeld(data)
    if not r.ok: return err[DynamicImage](r.err)
    ok(DynamicImage(kind: dkRgba16, rgba16: r.value))

proc normalizeToRgba8*(img: DynamicImage): ImageResult[RgbaImage] =
  ## Convert any DynamicImage variant to 8-bit RGBA. 16-bit channels map
  ## exactly (`v div 257`: 0→0, 65535→255); float32 clamps [0,1] then
  ## scales (HDR: clamp, no tone mapping in v1). Never blanks: every
  ## variant is handled, unlike `toRgba8`.
  case img.kind
  of dkRgba8: ok(img.rgba8)
  of dkRgb8:
    let s = img.rgb8
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2], 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLuma8:
    let s = img.luma8
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [p.data[0], p.data[0], p.data[0], 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLumaA8:
    let s = img.lumaA8
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [p.data[0], p.data[0], p.data[0], p.data[1]])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLuma16:
    let s = img.luma16
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      let v = uint8(int(p.data[0]) div 257)
      outP[i] = Rgba[uint8](data: [v, v, v, 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLumaA16:
    let s = img.lumaA16
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      let v = uint8(int(p.data[0]) div 257)
      let a = uint8(int(p.data[1]) div 257)
      outP[i] = Rgba[uint8](data: [v, v, v, a])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkRgb16:
    let s = img.rgb16
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [uint8(int(p.data[0]) div 257),
        uint8(int(p.data[1]) div 257), uint8(int(p.data[2]) div 257), 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkRgba16:
    let s = img.rgba16
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [uint8(int(p.data[0]) div 257),
        uint8(int(p.data[1]) div 257), uint8(int(p.data[2]) div 257),
        uint8(int(p.data[3]) div 257)])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLuma32F:
    let s = img.luma32f
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      let v = uint8(clamp(int(p.data[0] * 255.0 + 0.5), 0, 255))
      outP[i] = Rgba[uint8](data: [v, v, v, 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkLumaA32F:
    let s = img.lumaA32f
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      let v = uint8(clamp(int(p.data[0] * 255.0 + 0.5), 0, 255))
      let a = uint8(clamp(int(p.data[1] * 255.0 + 0.5), 0, 255))
      outP[i] = Rgba[uint8](data: [v, v, v, a])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkRgb32F:
    let s = img.rgb32f
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [
        uint8(clamp(int(p.data[0] * 255.0 + 0.5), 0, 255)),
        uint8(clamp(int(p.data[1] * 255.0 + 0.5), 0, 255)),
        uint8(clamp(int(p.data[2] * 255.0 + 0.5), 0, 255)), 255'u8])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))
  of dkRgba32F:
    let s = img.rgba32f
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [
        uint8(clamp(int(p.data[0] * 255.0 + 0.5), 0, 255)),
        uint8(clamp(int(p.data[1] * 255.0 + 0.5), 0, 255)),
        uint8(clamp(int(p.data[2] * 255.0 + 0.5), 0, 255)),
        uint8(clamp(int(p.data[3] * 255.0 + 0.5), 0, 255))])
    ok(RgbaImage(width: s.width, height: s.height, pixels: move(outP)))

type WebpRequest* = object
  ## Fluent WebP compression request: `img.toWebp(90).crop(...).encode()`.
  img*: DynamicImage
  quality*: int
  lossless*: bool
  hasCrop*: bool
  cropRect*: Rect
  reqErr*: Option[ImageError]

proc toWebp*(img: DynamicImage, quality = 75): WebpRequest =
  if quality < 1 or quality > 100:
    return WebpRequest(img: img, quality: quality, lossless: false,
      hasCrop: false, cropRect: initRect(0, 0, 0, 0),
      reqErr: some(paramError(pkGeneric, "webp: quality 1..100")))
  WebpRequest(img: img, quality: quality, lossless: false, hasCrop: false,
    cropRect: initRect(0, 0, 0, 0), reqErr: none(ImageError))

proc lossless*(req: WebpRequest, on = true): WebpRequest =
  if req.reqErr.isSome: return req
  var r = req
  r.lossless = on
  r

proc crop*(req: WebpRequest, x, y, w, h: uint32): WebpRequest =
  ## Strict crop chained onto a compression request. Coordinates are
  ## relative to the current request image (a previous crop, if any).
  if req.reqErr.isSome: return req
  if w == 0 or h == 0:
    var r = req
    r.reqErr = some(paramError(pkDimensionMismatch, "crop: empty"))
    return r
  let (baseW, baseH) =
    if req.hasCrop: (req.cropRect.width, req.cropRect.height)
    else: req.img.dimensions()
  if uint64(x) + uint64(w) > uint64(baseW) or
      uint64(y) + uint64(h) > uint64(baseH):
    var r = req
    r.reqErr = some(paramError(pkDimensionMismatch, "crop: out of bounds"))
    return r
  var r = req
  if req.hasCrop:
    r.cropRect = initRect(req.cropRect.x + x, req.cropRect.y + y, w, h)
  else:
    r.cropRect = initRect(x, y, w, h)
  r.hasCrop = true
  r

proc encode*(req: WebpRequest): ImageResult[seq[uint8]] =
  if req.reqErr.isSome:
    return err[seq[uint8]](req.reqErr.get)
  var src = req.img
  if req.hasCrop:
    let c = cropImage(src, req.cropRect.x, req.cropRect.y,
      req.cropRect.width, req.cropRect.height)
    if not c.ok: return err[seq[uint8]](c.err)
    src = c.value
  let (w, h) = src.dimensions()
  if w == 0 or h == 0:
    return err[seq[uint8]](paramError(pkDimensionMismatch, "webp: empty"))
  if w > uint32(WebpMaxDim) or h > uint32(WebpMaxDim):
    return err[seq[uint8]](limitError(lkDimensionError, "webp: too large"))
  let n = normalizeToRgba8(src)
  if not n.ok: return err[seq[uint8]](n.err)
  if req.lossless:
    return encodeWebp(DynamicImage(kind: dkRgba8, rgba8: n.value))
  encodeWebpLossy(n.value, req.quality)

proc convertToWebp*(data: seq[uint8], quality = 75,
    lossless = false): ImageResult[seq[uint8]] =
  ## Convert any supported encoded image to WebP. Format is sniffed;
  ## first frame wins for animated / multi-image inputs.
  let d = decodeImage(data)
  if not d.ok: return err[seq[uint8]](d.err)
  d.value.toWebp(quality).lossless(lossless).encode()
