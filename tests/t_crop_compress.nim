import unittest
import std/strutils
import image
import image/codecs/jpeg

proc fillRgb(w, h: uint32): DynamicImage =
  var px = newSeq[Rgb[uint8]](int(w) * int(h))
  for y in 0..<int(h):
    for x in 0..<int(w):
      px[y * int(w) + x] = Rgb[uint8](data: [uint8(x mod 256),
        uint8(y mod 256), uint8((x + y) mod 256)])
  DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: w, height: h, pixels: px))

test "crop all 12 variants exact pixels":
  let w = 4'u32
  let h = 4'u32
  # build one image per variant with index-derived content
  var l8 = newSeq[Luma[uint8]](16)
  var la8 = newSeq[LumaA[uint8]](16)
  var r8 = newSeq[Rgb[uint8]](16)
  var ra8 = newSeq[Rgba[uint8]](16)
  var l16 = newSeq[Luma[uint16]](16)
  var la16 = newSeq[LumaA[uint16]](16)
  var r16 = newSeq[Rgb[uint16]](16)
  var ra16 = newSeq[Rgba[uint16]](16)
  var l32 = newSeq[Luma[float32]](16)
  var la32 = newSeq[LumaA[float32]](16)
  var r32 = newSeq[Rgb[float32]](16)
  var ra32 = newSeq[Rgba[float32]](16)
  for i in 0..<16:
    l8[i] = Luma[uint8](data: [uint8(i)])
    la8[i] = LumaA[uint8](data: [uint8(i), 200'u8])
    r8[i] = Rgb[uint8](data: [uint8(i), uint8(i + 1), uint8(i + 2)])
    ra8[i] = Rgba[uint8](data: [uint8(i), uint8(i + 1), uint8(i + 2), 255'u8])
    l16[i] = Luma[uint16](data: [uint16(i * 257)])
    la16[i] = LumaA[uint16](data: [uint16(i * 257), 65535'u16])
    r16[i] = Rgb[uint16](data: [uint16(i), uint16(i + 1), uint16(i + 2)])
    ra16[i] = Rgba[uint16](data: [uint16(i), uint16(i + 1), uint16(i + 2),
      65535'u16])
    l32[i] = Luma[float32](data: [float32(i) / 16.0f32])
    la32[i] = LumaA[float32](data: [float32(i) / 16.0f32, 1.0f32])
    r32[i] = Rgb[float32](data: [float32(i) / 16.0f32,
      float32(i + 1) / 16.0f32, float32(i + 2) / 16.0f32])
    ra32[i] = Rgba[float32](data: [float32(i) / 16.0f32,
      float32(i + 1) / 16.0f32, float32(i + 2) / 16.0f32, 1.0f32])
  let imgs = [
    DynamicImage(kind: dkLuma8, luma8: GrayImage(width: w, height: h, pixels: l8)),
    DynamicImage(kind: dkLumaA8, lumaA8: GrayAlphaImage(width: w, height: h, pixels: la8)),
    DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: w, height: h, pixels: r8)),
    DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: w, height: h, pixels: ra8)),
    DynamicImage(kind: dkLuma16, luma16: Gray16Image(width: w, height: h, pixels: l16)),
    DynamicImage(kind: dkLumaA16, lumaA16: GrayAlpha16Image(width: w, height: h, pixels: la16)),
    DynamicImage(kind: dkRgb16, rgb16: Rgb16Image(width: w, height: h, pixels: r16)),
    DynamicImage(kind: dkRgba16, rgba16: Rgba16Image(width: w, height: h, pixels: ra16)),
    DynamicImage(kind: dkLuma32F, luma32f: Gray32FImage(width: w, height: h, pixels: l32)),
    DynamicImage(kind: dkLumaA32F, lumaA32f: GrayAlpha32FImage(width: w, height: h, pixels: la32)),
    DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: w, height: h, pixels: r32)),
    DynamicImage(kind: dkRgba32F, rgba32f: Rgba32FImage(width: w, height: h, pixels: ra32)),
  ]
  for img in imgs:
    let c = cropImage(img, 1, 1, 2, 2)
    check c.ok
    check c.value.dimensions() == (2'u32, 2'u32)
    check c.value.kind == img.kind
    # top-left of crop == source pixel (1,1) == index 5
    case img.kind
    of dkLuma8: check c.value.luma8.pixels[0].data[0] == 5'u8
    of dkLumaA8: check c.value.lumaA8.pixels[0].data[0] == 5'u8
    of dkRgb8: check c.value.rgb8.pixels[0].data == [5'u8, 6, 7]
    of dkRgba8: check c.value.rgba8.pixels[0].data == [5'u8, 6, 7, 255]
    of dkLuma16: check c.value.luma16.pixels[0].data[0] == uint16(5 * 257)
    of dkLumaA16: check c.value.lumaA16.pixels[0].data[0] == uint16(5 * 257)
    of dkRgb16: check c.value.rgb16.pixels[0].data == [5'u16, 6, 7]
    of dkRgba16: check c.value.rgba16.pixels[0].data == [5'u16, 6, 7, 65535]
    of dkLuma32F: check c.value.luma32f.pixels[0].data[0] == 5.0f32 / 16.0f32
    of dkLumaA32F: check c.value.lumaA32f.pixels[0].data[0] == 5.0f32 / 16.0f32
    of dkRgb32F: check c.value.rgb32f.pixels[0].data[1] == 6.0f32 / 16.0f32
    of dkRgba32F: check c.value.rgba32f.pixels[0].data[2] == 7.0f32 / 16.0f32

test "crop full image edge and single pixel":
  let img = fillRgb(4, 4)
  let full = cropImage(img, 0, 0, 4, 4)
  check full.ok
  check full.value.rgb8.pixels == img.rgb8.pixels
  let edge = cropImage(img, 2, 2, 2, 2)
  check edge.ok
  check edge.value.rgb8.pixels[0].data == img.rgb8.pixels[2 * 4 + 2].data
  check edge.value.rgb8.pixels[3].data == img.rgb8.pixels[3 * 4 + 3].data
  let one = cropImage(img, 3, 3, 1, 1)
  check one.ok
  check one.value.dimensions() == (1'u32, 1'u32)
  check one.value.rgb8.pixels[0].data == img.rgb8.pixels[15].data

test "crop strict rejection":
  let img = fillRgb(4, 4)
  check cropImage(img, 0, 0, 0, 2).ok == false # empty width
  check cropImage(img, 0, 0, 2, 0).ok == false # empty height
  check cropImage(img, 3, 3, 2, 2).ok == false # partially outside
  check cropImage(img, 4, 0, 1, 1).ok == false # x on boundary
  check cropImage(img, 0, 0, 5, 5).ok == false # larger than source
  # overflow-adjacent: wrapping x+w must not become valid
  check cropImage(img, high(uint32), 0, 2, 2).ok == false
  check cropImage(img, 0, high(uint32), 2, 2).ok == false
  check cropImage(img, high(uint32) - 1, 0, 2, 2).ok == false
  # exact fit at the far edge is accepted
  check cropImage(img, 2, 2, 2, 2).ok

test "crop leaves source unchanged":
  let img = fillRgb(4, 4)
  let before = img.rgb8.pixels
  let c = cropImage(img, 0, 0, 2, 2)
  check c.ok
  check img.rgb8.pixels == before
  check img.dimensions() == (4'u32, 4'u32)

test "jpeg quality bounds":
  let img = fillRgb(8, 8)
  for q in [1, 50, 90, 100]:
    check encodeJpeg(img, q).ok
  check encodeJpeg(img, 0).ok == false
  check encodeJpeg(img, -5).ok == false
  check encodeJpeg(img, 101).ok == false
  check img.compress(0).encode().ok == false
  check img.compress(101).encode().ok == false
  check img.compress(50).encode().ok

test "jpeg fluent first error wins":
  let img = fillRgb(8, 8)
  let r1 = img.compress(0).crop(0, 0, 0, 0).encode()
  check r1.ok == false
  check r1.err.msg.contains("quality")
  let r2 = img.compress(90).crop(7, 7, 2, 2).encode()
  check r2.ok == false
  check r2.err.msg.contains("out of bounds")
  # chained crop is relative to the previous crop: (3,3,2,2) exceeds 4x4
  let r3 = img.compress(90).crop(2, 2, 4, 4).crop(3, 3, 2, 2).encode()
  check r3.ok == false
  # composition lands in original coordinates
  let req = img.compress(90).crop(2, 2, 4, 4).crop(1, 1, 2, 2)
  check req.cropRect.x == 3'u32
  check req.cropRect.y == 3'u32

test "jpeg fluent crop encode dimensions":
  var px = newSeq[Rgb[uint8]](320 * 320)
  for i in 0..<px.len:
    px[i] = Rgb[uint8](data: [uint8(i mod 251), uint8((i * 2) mod 251),
      uint8((i * 3) mod 251)])
  let big = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 320, height: 320, pixels: px))
  let enc = big.compress(50).crop(300, 300, 20, 20).encode()
  check enc.ok
  let dec = decodeJpeg(enc.value)
  check dec.ok
  check dec.value.dimensions() == (20'u32, 20'u32)

test "jpeg optimized smaller deterministic decodable":
  var px = newSeq[Rgb[uint8]](256)
  for y in 0..<16:
    for x in 0..<16:
      px[y * 16 + x] = Rgb[uint8](data: [uint8(x * 16), uint8(y * 16),
        128'u8])
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 16, height: 16, pixels: px))
  let fixed = encodeJpeg(img, 75, true, false)
  let optim = encodeJpeg(img, 75, true, true)
  check fixed.ok
  check optim.ok
  check optim.value.len < fixed.value.len
  let again = encodeJpeg(img, 75, true, true)
  check again.value == optim.value
  let d = decodeJpeg(optim.value)
  check d.ok
  check d.value.kind == dkRgb8
  check d.value.dimensions() == (16'u32, 16'u32)
  # fluent opt-in matches the direct flag
  let viaFluent = img.compress(75).optimized().encode()
  check viaFluent.ok
  check viaFluent.value == optim.value

test "jpeg alpha dropped bit-exact":
  var px = newSeq[Rgba[uint8]](64)
  var rgb = newSeq[Rgb[uint8]](64)
  for i in 0..<64:
    px[i] = Rgba[uint8](data: [uint8(i * 3), uint8(i * 3 + 1),
      uint8(i * 3 + 2), uint8(i)])
    rgb[i] = Rgb[uint8](data: [uint8(i * 3), uint8(i * 3 + 1),
      uint8(i * 3 + 2)])
  let a = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 8, height: 8, pixels: px))
  let c = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 8, height: 8, pixels: rgb))
  let ea = encodeJpeg(a, 90)
  let ec = encodeJpeg(c, 90)
  check ea.ok
  check ec.ok
  check ea.value == ec.value
  var lx = newSeq[LumaA[uint8]](64)
  var lm = newSeq[Luma[uint8]](64)
  for i in 0..<64:
    lx[i] = LumaA[uint8](data: [uint8(i * 4), uint8(i)])
    lm[i] = Luma[uint8](data: [uint8(i * 4)])
  let la = DynamicImage(kind: dkLumaA8,
    lumaA8: GrayAlphaImage(width: 8, height: 8, pixels: lx))
  let ll = DynamicImage(kind: dkLuma8,
    luma8: GrayImage(width: 8, height: 8, pixels: lm))
  let ela = encodeJpeg(la, 90)
  check ela.ok
  let dll = decodeJpeg(ela.value)
  check dll.ok
  check dll.value.kind == dkLuma8
  check encodeJpeg(ll, 90).value == ela.value

test "jpeg rejects non 8-bit input":
  var px16 = newSeq[Luma[uint16]](64)
  for i in 0..<64: px16[i] = Luma[uint16](data: [uint16(i * 257)])
  let img16 = DynamicImage(kind: dkLuma16,
    luma16: Gray16Image(width: 8, height: 8, pixels: px16))
  let r16 = encodeJpeg(img16, 90)
  check r16.ok == false
  check r16.err.kind == ekUnsupported
  check img16.compress(90).encode().ok == false
  var pxf = newSeq[Rgb[float32]](16)
  for i in 0..<16:
    pxf[i] = Rgb[float32](data: [0.5f32, 0.25f32, 0.125f32])
  let imgf = DynamicImage(kind: dkRgb32F,
    rgb32f: Rgb32FImage(width: 4, height: 4, pixels: pxf))
  check encodeJpeg(imgf, 90).ok == false
