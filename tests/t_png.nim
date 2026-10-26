import unittest
import image
import image/codecs/png
import image/zlibwrap

test "png rgb8 round-trip":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]), Rgb[uint8](data: [0'u8, 255, 0]),
             Rgb[uint8](data: [0'u8, 0, 255]), Rgb[uint8](data: [255'u8, 255, 255])]
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 2, height: 2, pixels: px))
  let enc = encodePng(img)
  check enc.ok
  check enc.value[0] == 137'u8
  let dec = decodePng(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.rgb8.pixels == px

test "png rgba8 round-trip":
  var px = @[Rgba[uint8](data: [1'u8, 2, 3, 4]), Rgba[uint8](data: [5'u8, 6, 7, 250])]
  let img = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 2, height: 1, pixels: px))
  let enc = encodePng(img)
  check enc.ok
  let dec = decodePng(enc.value)
  check dec.ok
  check dec.value.rgba8.pixels == px

test "png luma + grayalpha":
  var px = @[Luma[uint8](data: [0'u8]), Luma[uint8](data: [200'u8])]
  let img = DynamicImage(kind: dkLuma8, luma8: GrayImage(width: 2, height: 1, pixels: px))
  let enc = encodePng(img)
  check enc.ok
  let dec = decodePng(enc.value)
  check dec.ok
  check dec.value.kind == dkLuma8
  check dec.value.luma8.pixels == px

test "png 16-bit":
  var px = @[Rgb[uint16](data: [65535'u16, 0, 0]), Rgb[uint16](data: [0'u16, 65535, 0])]
  let img = DynamicImage(kind: dkRgb16, rgb16: Rgb16Image(width: 2, height: 1, pixels: px))
  let enc = encodePng(img)
  check enc.ok
  let dec = decodePng(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb16
  check dec.value.rgb16.pixels == px

test "png bad signature":
  check decodePng(@[0'u8, 1, 2, 3]).ok == false

test "png CRC mismatch":
  var px = @[Rgb[uint8](data: [1'u8, 2, 3])]
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 1, height: 1, pixels: px))
  var enc = encodePng(img).value
  enc[20] = enc[20] xor 0xFF
  check decodePng(enc).ok == false

test "png adam7 1x1":
  var ihdr = @[0'u8, 0, 0, 1, 0, 0, 0, 1, 8, 0, 0, 0, 1]
  let comp = deflateZlib(@[0'u8, 200]).value
  proc chunk(t: array[4, uint8], body: seq[uint8]): seq[uint8] =
    var r = newSeq[uint8](8 + body.len + 4)
    let n = uint32(body.len)
    r[0]=uint8((n shr 24) and 0xFF); r[1]=uint8((n shr 16) and 0xFF)
    r[2]=uint8((n shr 8) and 0xFF); r[3]=uint8(n and 0xFF)
    for i in 0..3: r[4+i] = t[i]
    for i, b in body: r[8+i] = b
    let c = chunkCrc(t, body)
    r[8+body.len]=uint8((c shr 24) and 0xFF); r[8+body.len+1]=uint8((c shr 16) and 0xFF)
    r[8+body.len+2]=uint8((c shr 8) and 0xFF); r[8+body.len+3]=uint8(c and 0xFF)
    r
  var data = @[137'u8, 80, 78, 71, 13, 10, 26, 10]
  data.add(chunk([uint8('I'),uint8('H'),uint8('D'),uint8('R')], ihdr))
  data.add(chunk([uint8('I'),uint8('D'),uint8('A'),uint8('T')], comp))
  data.add(chunk([uint8('I'),uint8('E'),uint8('N'),uint8('D')], @[]))
  let dec = decodePng(data)
  check dec.ok
  check dec.value.kind == dkLuma8
  check dec.value.luma8.pixels[0].data == [200'u8]
