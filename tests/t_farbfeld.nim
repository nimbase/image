import unittest
import image
import image/codecs/farbfeld

test "farbfeld round-trip":
  var px = @[
    Rgba[uint16](data: [0'u16, 0, 0, 65535'u16]),
    Rgba[uint16](data: [65535'u16, 0, 0, 65535'u16]),
    Rgba[uint16](data: [0'u16, 65535, 0, 65535'u16]),
    Rgba[uint16](data: [0'u16, 0, 65535, 65535'u16]),
  ]
  let img = Rgba16Image(width: 2, height: 2, pixels: px)
  let enc = encodeFarbfeld(img)
  check enc.len == 16 + 4 * 8
  check enc[0] == uint8('f')
  let dec = decodeFarbfeld(enc)
  check dec.ok
  check dec.value.width == 2
  check dec.value.height == 2
  check dec.value.pixels == px

test "farbfeld bad magic":
  let bad = @[0'u8, 1, 2, 3, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 0]
  check decodeFarbfeld(bad).ok == false

test "farbfeld truncated":
  var px = @[Rgba[uint16](data: [1'u16, 2, 3, 4])]
  let img = Rgba16Image(width: 1, height: 1, pixels: px)
  var enc = encodeFarbfeld(img)
  enc.setLen(enc.len - 1)
  check decodeFarbfeld(enc).ok == false
