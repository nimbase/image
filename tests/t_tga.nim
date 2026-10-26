import unittest
import image
import image/codecs/tga

test "tga rgb8 round-trip top-left":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]), Rgb[uint8](data: [0'u8, 255, 0]),
             Rgb[uint8](data: [0'u8, 0, 255]), Rgb[uint8](data: [255'u8, 255, 255])]
  let img = RgbImage(width: 2, height: 2, pixels: px)
  let enc = encodeTgaRgb8(img)
  check enc.len == 18 + 12
  let dec = decodeTga(enc)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.rgb8.pixels == px

test "tga rgba8 round-trip":
  var px = @[Rgba[uint8](data: [1'u8, 2, 3, 4]), Rgba[uint8](data: [5'u8, 6, 7, 8])]
  let img = RgbaImage(width: 2, height: 1, pixels: px)
  let enc = encodeTgaRgba8(img)
  let dec = decodeTga(enc)
  check dec.ok
  check dec.value.rgba8.pixels == px

test "tga bottom-left orientation flips":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]), Rgb[uint8](data: [0'u8, 255, 0])]
  let img = RgbImage(width: 2, height: 1, pixels: px)
  var enc = encodeTgaRgb8(img)
  enc[17] = 0x00 # bottom-left
  let dec = decodeTga(enc)
  check dec.ok
  check dec.value.rgb8.pixels == px

test "tga RLE truecolor":
  # 4x1 red run: header + 1 RLE packet (0x83) + BGR pixel
  var data = newSeq[uint8](18 + 1 + 3)
  data[2] = 10 # RunTrueColor
  data[12] = 4; data[14] = 1
  data[16] = 24; data[17] = 0x20
  data[18] = 0x83
  data[19] = 0; data[20] = 0; data[21] = 255
  let dec = decodeTga(data)
  check dec.ok
  check dec.value.rgb8.pixels.len == 4
  for p in dec.value.rgb8.pixels:
    check p.data == [255'u8, 0, 0]

test "tga bad type":
  var data = newSeq[uint8](18)
  data[2] = 99
  data[12] = 1; data[14] = 1; data[16] = 24
  check decodeTga(data).ok == false
