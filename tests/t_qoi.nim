import unittest
import image
import image/codecs/qoi

test "qoi header parse":
  let hdr = @[uint8('q'), uint8('o'), uint8('i'), uint8('f'),
    0'u8, 0, 0, 2, 0, 0, 0, 2, 4, 0]
  let h = parseQoiHeader(hdr)
  check h.ok
  check h.value.width == 2
  check h.value.height == 2
  check h.value.channels == 4

test "qoi round-trip rgba":
  var px = newSeq[Rgba[uint8]](4)
  px[0] = Rgba[uint8](data: [255'u8, 0, 0, 255'u8])
  px[1] = Rgba[uint8](data: [0'u8, 255, 0, 255'u8])
  px[2] = Rgba[uint8](data: [0'u8, 0, 255, 255'u8])
  px[3] = Rgba[uint8](data: [255'u8, 255, 255, 255'u8])
  let img = RgbaImage(width: 2, height: 2, pixels: px)
  let enc = encodeQoi(img)
  check enc.len > 14
  let dec = decodeQoi(enc)
  check dec.ok
  check dec.value.width == 2
  check dec.value.height == 2
  check dec.value.pixels == px

test "qoi round-trip single color run":
  var px = newSeq[Rgba[uint8]](16)
  for i in 0..<16:
    px[i] = Rgba[uint8](data: [10'u8, 20, 30, 255'u8])
  let img = RgbaImage(width: 4, height: 4, pixels: px)
  let enc = encodeQoi(img)
  # run encoding should be compact
  check enc.len < 14 + 16 * 4
  let dec = decodeQoi(enc)
  check dec.ok
  check dec.value.pixels == px

test "qoi bad magic":
  check parseQoiHeader(@[0'u8, 1, 2, 3]).ok == false
