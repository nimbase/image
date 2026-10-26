import unittest
import image
import image/codecs/pnm

test "pnm P6 round-trip":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]),
             Rgb[uint8](data: [0'u8, 255, 0]),
             Rgb[uint8](data: [0'u8, 0, 255]),
             Rgb[uint8](data: [255'u8, 255, 255])]
  let img = RgbImage(width: 2, height: 2, pixels: px)
  let enc = encodePnmRgb8(img)
  let dec = decodePnm(enc)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.rgb8.pixels == px

test "pnm P5 round-trip":
  var px = @[Luma[uint8](data: [0'u8]), Luma[uint8](data: [128'u8]),
             Luma[uint8](data: [200'u8]), Luma[uint8](data: [255'u8])]
  let img = GrayImage(width: 2, height: 2, pixels: px)
  let enc = encodePnmGray8(img)
  let dec = decodePnm(enc)
  check dec.ok
  check dec.value.luma8.pixels == px

test "pnm P3 ascii":
  let s = "P3\n2 1\n255\n255 0 0 0 255 0\n"
  var data = newSeq[uint8](s.len)
  for i, c in s: data[i] = uint8(c)
  let dec = decodePnm(data)
  check dec.ok
  check dec.value.rgb8.pixels[0].data == [255'u8, 0, 0]
  check dec.value.rgb8.pixels[1].data == [0'u8, 255, 0]

test "pnm comment handling":
  let s = "P5\n# comment\n2 1\n255\n\x00\xFF"
  var data = newSeq[uint8](s.len)
  for i, c in s: data[i] = uint8(c)
  let dec = decodePnm(data)
  check dec.ok
  check dec.value.luma8.pixels[1].data[0] == 255

test "pnm bad magic":
  let s = "P9\n"
  var data = newSeq[uint8](s.len)
  for i, c in s: data[i] = uint8(c)
  check decodePnm(data).ok == false
