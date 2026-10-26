## Farbfeld codec — references/image/src/codecs/farbfeld.rs
import streams
import ../color
import ../error
import ../io
import ../decoder
import ../buffer
import ../endian

const FarbfeldMagic* = "farbfeld"

type
  FarbfeldDecoder* = object
    width*, height*: uint32
    prepared*: bool

  FarbfeldEncoder* = object
    discard

proc prepareFarbfeld*(s: Stream): ImageResult[DecoderPreparedImage] =
  let magic = s.readStr(8)
  if magic != FarbfeldMagic:
    return err[DecoderPreparedImage](decodingError("farbfeld: bad magic"))
  let w = readU32BE(s)
  let h = readU32BE(s)
  ok(initPrepared(w, h, ctRgba16))

proc readFarbfeldImage*(s: Stream, buf: var openArray[uint8], w, h: uint32): ImageResult[DecodedImageAttributes] =
  let total = uint64(w) * uint64(h) * 8
  if uint64(buf.len) != total:
    return err[DecodedImageAttributes](paramError(pkBufferSizeMismatch, "farbfeld buffer size"))
  let raw = s.readStr(int(total))
  if raw.len != int(total):
    return err[DecodedImageAttributes](decodingError("farbfeld: truncated"))
  for i in 0..<raw.len:
    buf[i] = uint8(raw[i])
  ok(defaultImageAttributes())

proc writeFarbfeld*(s: Stream, buf: openArray[uint8], w, h: uint32,
    color: ExtendedColorType): ImageResult[bool] =
  if color.kind != ekRgba16:
    return err[bool](unsupportedError(ukColor, "farbfeld requires Rgba16"))
  if uint64(buf.len) != uint64(w) * uint64(h) * 8:
    return err[bool](paramError(pkBufferSizeMismatch, "farbfeld buffer size"))
  s.write(FarbfeldMagic)
  writeU32BE(s, w)
  writeU32BE(s, h)
  var raw = newString(buf.len)
  for i in 0..<buf.len: raw[i] = char(buf[i])
  s.write(raw)
  ok(true)

proc decodeFarbfeld*(data: seq[uint8]): ImageResult[Rgba16Image] =
  if data.len < 16:
    return err[Rgba16Image](decodingError("farbfeld: too short"))
  for i, c in FarbfeldMagic:
    if data[i] != uint8(c):
      return err[Rgba16Image](decodingError("farbfeld: bad magic"))
  let w = u32BE(data, 8)
  let h = u32BE(data, 12)
  let npix = uint64(w) * uint64(h)
  if uint64(data.len - 16) < npix * 8:
    return err[Rgba16Image](decodingError("farbfeld: truncated"))
  var px = newSeq[Rgba[uint16]](int(npix))
  var off = 16
  for i in 0..<px.len:
    let r = (uint16(data[off]) shl 8) or uint16(data[off+1])
    let g = (uint16(data[off+2]) shl 8) or uint16(data[off+3])
    let b = (uint16(data[off+4]) shl 8) or uint16(data[off+5])
    let a = (uint16(data[off+6]) shl 8) or uint16(data[off+7])
    px[i] = Rgba[uint16](data: [r, g, b, a])
    off += 8
  ok(Rgba16Image(width: w, height: h, pixels: px))

proc encodeFarbfeld*(img: Rgba16Image): seq[uint8] =
  result = newSeq[uint8](16 + img.pixels.len * 8)
  for i, c in FarbfeldMagic: result[i] = uint8(c)
  result[8] = uint8((img.width shr 24) and 0xFF)
  result[9] = uint8((img.width shr 16) and 0xFF)
  result[10] = uint8((img.width shr 8) and 0xFF)
  result[11] = uint8(img.width and 0xFF)
  result[12] = uint8((img.height shr 24) and 0xFF)
  result[13] = uint8((img.height shr 16) and 0xFF)
  result[14] = uint8((img.height shr 8) and 0xFF)
  result[15] = uint8(img.height and 0xFF)
  var off = 16
  for p in img.pixels:
    for v in p.data:
      result[off] = uint8((v shr 8) and 0xFF)
      result[off+1] = uint8(v and 0xFF)
      off += 2
