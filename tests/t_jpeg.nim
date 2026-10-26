import unittest
import std/os
import image
import image/codecs/jpeg

test "jpeg gray round-trip":
  var px = newSeq[Luma[uint8]](64)
  for i in 0..<64: px[i] = Luma[uint8](data: [uint8(i * 4)])
  let img = DynamicImage(kind: dkLuma8, luma8: GrayImage(width: 8, height: 8, pixels: px))
  let enc = encodeJpeg(img, 90, subsample = false)
  check enc.ok
  check enc.value[0] == 0xFF and enc.value[1] == 0xD8
  let dec = decodeJpeg(enc.value)
  check dec.ok
  check dec.value.kind == dkLuma8
  check dec.value.luma8.width == 8
  # quality 90: allow small loss
  var maxDiff = 0
  for i in 0..<64:
    maxDiff = max(maxDiff, abs(int(dec.value.luma8.pixels[i].data[0]) - int(px[i].data[0])))
  check maxDiff <= 12

test "jpeg rgb round-trip 420":
  var px = newSeq[Rgb[uint8]](256)
  for y in 0..<16:
    for x in 0..<16:
      px[y*16+x] = Rgb[uint8](data: [uint8(x*16), uint8(y*16), 128'u8])
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 16, height: 16, pixels: px))
  let enc = encodeJpeg(img, 85, subsample = true)
  check enc.ok
  let dec = decodeJpeg(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (16'u32, 16'u32)

test "jpeg rgb round-trip 444":
  var px = newSeq[Rgb[uint8]](64)
  for i in 0..<64: px[i] = Rgb[uint8](data: [200'u8, 100, 50])
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 8, height: 8, pixels: px))
  let enc = encodeJpeg(img, 95, subsample = false)
  check enc.ok
  let dec = decodeJpeg(enc.value)
  check dec.ok
  var maxDiff = 0
  for i in 0..<64:
    for c in 0..2:
      maxDiff = max(maxDiff,
        abs(int(dec.value.rgb8.pixels[i].data[c]) - int(px[i].data[c])))
  check maxDiff <= 8

test "jpeg reference baseline":
  let p = "/Users/georgelemon/Development/nimbase/references/image/tests/images/jpg/iptc.jpg"
  if fileExists(p):
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeJpeg(raw)
    check dec.ok
    check dec.value.dimensions() == (64'u32, 48'u32)
  else:
    skip()

test "jpeg progressive unsupported":
  let p = "/Users/georgelemon/Development/nimbase/references/image/tests/images/jpg/progressive/cat.jpg"
  if fileExists(p):
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    check decodeJpeg(raw).ok == false
  else:
    skip()

test "jpeg bad data":
  check decodeJpeg(@[0xFF'u8, 0xD8, 0xFF, 0x00]).ok == false
  check decodeJpeg(@[0'u8, 1]).ok == false
