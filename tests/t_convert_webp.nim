import unittest
import std/strutils
import image

proc fillRgb(w, h: uint32): DynamicImage =
  var px = newSeq[Rgb[uint8]](int(w) * int(h))
  for y in 0..<int(h):
    for x in 0..<int(w):
      px[y * int(w) + x] = Rgb[uint8](data: [uint8(x mod 256),
        uint8(y mod 256), uint8((x + y) mod 256)])
  DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: w, height: h, pixels: px))

test "guessFormat new magics":
  check guessFormat([uint8('I'), uint8('I'), 42, 0]).f == fmtTiff
  check guessFormat([uint8('M'), uint8('M'), 0, 42]).f == fmtTiff
  check guessFormat([0'u8, 0, 1, 0, 1, 0]).f == fmtIco
  check guessFormat([uint8('P'), uint8('6'), 10]).f == fmtPnm
  check guessFormat([uint8('P'), uint8('3'), 32]).f == fmtPnm
  # bare TGA header (no footer), like our own encoder emits
  var tga = newSeq[uint8](18)
  tga[2] = 2; tga[12] = 4; tga[14] = 4; tga[16] = 24
  check guessFormat(tga).f == fmtTga
  check guessFormat([0x76'u8, 0x2F, 0x31, 0x01]).f == fmtOpenExr
  check guessFormat(@[0'u8, 1, 2, 3, 4, 5]).found == false
  check guessFormat(newSeq[uint8]()).found == false

test "decodeImage sniffs every encodable format":
  let img = fillRgb(8, 6)
  let pngB = encodePng(img).value
  check decodeImage(pngB).value.dimensions() == (8'u32, 6'u32)
  let jpgB = encodeJpeg(img, 100).value
  let dj = decodeImage(jpgB)
  check dj.ok
  check dj.value.dimensions() == (8'u32, 6'u32)
  let bmpB = encodeBmpRgb8(img.rgb8)
  check decodeImage(bmpB).value.dimensions() == (8'u32, 6'u32)
  var qpx = newSeq[Rgba[uint8]](48)
  for i in 0..<48:
    qpx[i] = Rgba[uint8](data: [uint8(i), uint8(i+1), uint8(i+2), 255'u8])
  let qoiB = encodeQoi(RgbaImage(width: 8, height: 6, pixels: qpx))
  let dq = decodeImage(qoiB)
  check dq.ok
  check dq.value.kind == dkRgba8
  let pnmB = encodePnmRgb8(img.rgb8)
  check decodeImage(pnmB).value.dimensions() == (8'u32, 6'u32)
  let tgaB = encodeTgaRgb8(img.rgb8)
  check decodeImage(tgaB).value.dimensions() == (8'u32, 6'u32)
  let tifB = encodeTiff(img).value
  check decodeImage(tifB).value.dimensions() == (8'u32, 6'u32)
  let icoB = encodeIco(@[img]).value
  check decodeImage(icoB).value.dimensions() == (8'u32, 6'u32)
  let gifB = encodeGif(@[newSeq[uint8](48)], 8, 6,
    @[(r: 10'u8, g: 20'u8, b: 30'u8), (r: 40'u8, g: 50'u8, b: 60'u8)])
  let dg = decodeImage(gifB)
  check dg.ok
  check dg.value.dimensions() == (8'u32, 6'u32)
  # 16-bit farbfeld + float hdr/exr sources
  var px16 = newSeq[Rgba[uint16]](4)
  for i in 0..<4:
    px16[i] = Rgba[uint16](data: [uint16(i*257), uint16(i*257),
      uint16(i*257), uint16(65535)])
  let ffB = encodeFarbfeld(Rgba16Image(width: 2, height: 2, pixels: px16))
  let df = decodeImage(ffB)
  check df.ok
  check df.value.kind == dkRgba16
  var fpx = newSeq[Rgb[float32]](4)
  for i in 0..<4:
    fpx[i] = Rgb[float32](data: [0.5f32, 0.25f32, 1.0f32])
  let hdrB = encodeHdr(Rgb32FImage(width: 2, height: 2, pixels: fpx))
  let dh = decodeImage(hdrB)
  check dh.ok
  check dh.value.kind == dkRgb32F
  let exrB = encodeExr(DynamicImage(kind: dkRgb32F,
    rgb32f: Rgb32FImage(width: 2, height: 2, pixels: fpx))).value
  let de = decodeImage(exrB)
  check de.ok
  check de.value.dimensions() == (2'u32, 2'u32)

test "decodeImage rejects garbage":
  check decodeImage(newSeq[uint8]()).ok == false
  check decodeImage(@[0'u8, 1, 2, 3]).ok == false
  check decodeImage(@[255'u8, 216, 255, 0]).ok == false # bad jpeg
  check decodeImage(@[137'u8, 80, 78, 71, 13, 10, 26, 10]).ok == false # truncated png

test "convert lossless round-trips pixel-exact":
  let img = fillRgb(8, 6)
  for raw in [encodePng(img).value, encodeBmpRgb8(img.rgb8),
      encodePnmRgb8(img.rgb8), encodeTgaRgb8(img.rgb8),
      encodeTiff(img).value, encodeIco(@[img]).value]:
    let c = convertToWebp(raw, lossless = true)
    require c.ok
    let back = decodeWebp(c.value)
    require back.ok
    check back.value.kind == dkRgb8
    check back.value.rgb8.pixels == img.rgb8.pixels
  # webp in, webp out is stable
  let w0 = convertToWebp(encodePng(img).value, lossless = true).value
  let w1 = convertToWebp(w0, lossless = true)
  require w1.ok
  require decodeWebp(w1.value).ok
  check decodeWebp(w1.value).value.rgb8.pixels == img.rgb8.pixels
  # jpeg source converts (lossy in, lossless out): dims + decodable
  let jc = convertToWebp(encodeJpeg(img, 100).value, lossless = true)
  require jc.ok
  require decodeWebp(jc.value).ok

test "convert handles gif animation frame 0 + alpha":
  var f0 = newSeq[uint8](16)
  var f1 = newSeq[uint8](16)
  for i in 0..<16: f1[i] = 1
  let pal = @[(r: 255'u8, g: 0'u8, b: 0'u8), (r: 0'u8, g: 0'u8, b: 255'u8)]
  let gifB = encodeGif(@[f0, f1], 4, 4, pal)
  let c = convertToWebp(gifB, lossless = true)
  require c.ok
  let back = decodeWebp(c.value)
  require back.ok
  check back.value.dimensions() == (4'u32, 4'u32)
  for p in back.value.rgb8.pixels:
    check p.data == [255'u8, 0, 0]
  # rgba with real alpha survives
  var apx = @[Rgba[uint8](data: [10'u8, 20, 30, 0]),
    Rgba[uint8](data: [40'u8, 50, 60, 128]),
    Rgba[uint8](data: [70'u8, 80, 90, 200]),
    Rgba[uint8](data: [1'u8, 2, 3, 255])]
  let aimg = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 2, height: 2, pixels: apx))
  let ac = convertToWebp(encodeQoi(aimg.rgba8), lossless = true)
  require ac.ok
  require decodeWebp(ac.value).ok
  check decodeWebp(ac.value).value.rgba8.pixels == apx

test "convert downconverts 16-bit and float exactly":
  var px16 = newSeq[Rgb[uint16]](4)
  let vals = [0'u16, 257, 32768, 65535]
  for i in 0..<4:
    px16[i] = Rgb[uint16](data: [vals[i], vals[i], vals[i]])
  let img16 = DynamicImage(kind: dkRgb16,
    rgb16: Rgb16Image(width: 2, height: 2, pixels: px16))
  let n16 = normalizeToRgba8(img16)
  check n16.ok
  check n16.value.pixels[0].data == [0'u8, 0, 0, 255]
  check n16.value.pixels[1].data == [1'u8, 1, 1, 255]
  check n16.value.pixels[3].data == [255'u8, 255, 255, 255]
  var fpx = @[Rgb[float32](data: [0.0f32, 0.5f32, 1.0f32]),
    Rgb[float32](data: [2.0f32, -1.0f32, 0.5f32]),
    Rgb[float32](data: [0.0f32, 0.0f32, 0.0f32]),
    Rgb[float32](data: [1.0f32, 1.0f32, 1.0f32])]
  let imgf = DynamicImage(kind: dkRgb32F,
    rgb32f: Rgb32FImage(width: 2, height: 2, pixels: fpx))
  let nf = normalizeToRgba8(imgf)
  check nf.ok
  check nf.value.pixels[0].data == [0'u8, 128, 255, 255]
  check nf.value.pixels[1].data == [255'u8, 0, 128, 255]
  # full convert path on a 16-bit source
  var a16 = newSeq[Rgba[uint16]](4)
  for i in 0..<4:
    a16[i] = Rgba[uint16](data: [uint16(i*257), 0, 0, 65535])
  let ffB = encodeFarbfeld(Rgba16Image(width: 2, height: 2, pixels: a16))
  let c = convertToWebp(ffB, lossless = true)
  require c.ok
  let back = decodeWebp(c.value)
  require back.ok
  check back.value.rgb8.pixels[3].data == [3'u8, 0, 0]
  # luma+alpha 8-bit keeps both channels
  var lx = @[LumaA[uint8](data: [200'u8, 100]), LumaA[uint8](data: [50'u8, 255]),
    LumaA[uint8](data: [0'u8, 0]), LumaA[uint8](data: [255'u8, 128])]
  let la = DynamicImage(kind: dkLumaA8,
    lumaA8: GrayAlphaImage(width: 2, height: 2, pixels: lx))
  let nl = normalizeToRgba8(la)
  check nl.ok
  check nl.value.pixels[0].data == [200'u8, 200, 200, 100]
  check nl.value.pixels[3].data == [255'u8, 255, 255, 128]

test "webp fluent quality bounds and first error wins":
  let img = fillRgb(8, 8)
  check img.toWebp(0).encode().ok == false
  check img.toWebp(101).encode().ok == false
  check img.toWebp(50).encode().ok
  check img.toWebp(50).lossless().encode().ok
  let r1 = img.toWebp(0).crop(0, 0, 0, 0).encode()
  check r1.ok == false
  check r1.err.msg.contains("quality")
  let r2 = img.toWebp(75).crop(7, 7, 2, 2).encode()
  check r2.ok == false
  check r2.err.msg.contains("out of bounds")

test "webp fluent crop encode dimensions":
  let img = fillRgb(16, 16)
  let enc = img.toWebp().crop(4, 4, 8, 8).lossless().encode()
  require enc.ok
  let dec = decodeWebp(enc.value)
  require dec.ok
  check dec.value.dimensions() == (8'u32, 8'u32)

test "convert lossy round-trips with bounded error":
  let img = fillRgb(24, 16)
  for q in [90, 75, 50]:
    let c = convertToWebp(encodePng(img).value, quality = q)
    require c.ok
    let back = decodeWebp(c.value)
    require back.ok
    check back.value.dimensions() == (24'u32, 16'u32)
    var sad = 0
    for i, p in back.value.rgb8.pixels:
      let o = img.rgb8.pixels[i]
      sad += abs(int(p.data[0]) - int(o.data[0])) +
        abs(int(p.data[1]) - int(o.data[1])) +
        abs(int(p.data[2]) - int(o.data[2]))
    # mean abs channel error stays small and grows as quality drops
    check float(sad) / float(24 * 16 * 3) < (if q == 90: 12.0
      elif q == 75: 20.0 else: 35.0)
  # lossy is smaller than lossless on smooth content
  let smooth = convertToWebp(encodePng(img).value, lossless = true)
  let lossy = convertToWebp(encodePng(img).value, quality = 75)
  require smooth.ok
  require lossy.ok
  check lossy.value.len < smooth.value.len

test "webp rejects empty and oversize":
  let empty = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 0, height: 0, pixels: @[]))
  check empty.toWebp().lossless().encode().ok == false
  let big = DynamicImage(kind: dkLuma8,
    luma8: GrayImage(width: 16385, height: 1,
      pixels: newSeq[Luma[uint8]](16385)))
  check big.toWebp().lossless().encode().ok == false
