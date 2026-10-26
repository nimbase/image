import unittest
import image
import image/codecs/bmp

test "bmp 24-bit round-trip":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]), Rgb[uint8](data: [0'u8, 255, 0]),
             Rgb[uint8](data: [0'u8, 0, 255]), Rgb[uint8](data: [255'u8, 255, 255])]
  let img = RgbImage(width: 2, height: 2, pixels: px)
  let enc = encodeBmpRgb8(img)
  check enc[0] == uint8('B')
  let dec = decodeBmp(enc)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.rgb8.pixels == px

test "bmp 32-bit rgba round-trip":
  var px = @[Rgba[uint8](data: [1'u8, 2, 3, 4]), Rgba[uint8](data: [5'u8, 6, 7, 8])]
  let img = RgbaImage(width: 2, height: 1, pixels: px)
  let enc = encodeBmpRgba8(img)
  let dec = decodeBmp(enc)
  check dec.ok
  check dec.value.kind == dkRgba8
  check dec.value.rgba8.pixels == px

test "bmp 1-bit palette":
  # 2x1, black+white
  var data = newSeq[uint8](14 + 40 + 8 + 4)
  data[0] = uint8('B'); data[1] = uint8('M')
  data[10] = 62
  data[14] = 40
  data[18] = 2; data[22] = 1
  data[26] = 1; data[28] = 1
  # palette: black, white
  data[54] = 0; data[55] = 0; data[56] = 0
  data[58] = 255; data[59] = 255; data[60] = 255
  data[62] = 0x40 # bits 01
  let dec = decodeBmp(data)
  check dec.ok
  check dec.value.rgb8.pixels[0].data == [0'u8, 0, 0]
  check dec.value.rgb8.pixels[1].data == [255'u8, 255, 255]

test "bmp 8-bit RLE8":
  # 2x1 palette + RLE8 encoded run of 2
  var data = newSeq[uint8](14 + 40 + 8 + 4)
  data[0] = uint8('B'); data[1] = uint8('M')
  data[10] = 62
  data[14] = 40
  data[18] = 2; data[22] = 1
  data[26] = 1; data[28] = 8
  data[30] = 1 # BI_RLE8
  data[46] = 2 # colors used
  data[54] = 0; data[55] = 0; data[56] = 255 # red
  data[58] = 0; data[59] = 255; data[60] = 0 # green
  # pixel data: count=2 val=1, eof
  data[62] = 2; data[63] = 1; data[64] = 0; data[65] = 1
  let dec = decodeBmp(data)
  check dec.ok
  check dec.value.rgb8.pixels[0].data == [0'u8, 255, 0]
  check dec.value.rgb8.pixels[1].data == [0'u8, 255, 0]

test "bmp bad signature":
  check decodeBmp(@[0'u8, 1, 2]).ok == false
