import unittest
import image
import image/codecs/hdr

test "hdr rgbe round-trip":
  check rgbeToHdr((128'u8, 64'u8, 192'u8, 129'u8)).data == [1.0'f32, 0.5, 1.5]
  let (r, g, b, e) = hdrToRgbe(1.0, 0.5, 1.5)
  check (r, g, b, e) == (128'u8, 64'u8, 192'u8, 129'u8)
  check hdrToRgbe(0, 0, 0) == (0'u8, 0'u8, 0'u8, 0'u8)

test "hdr flat round-trip small width":
  var px = @[Rgb[float32](data: [1.0'f32, 0.5, 0.25]),
             Rgb[float32](data: [0.0'f32, 0.0, 0.0])]
  let img = Rgb32FImage(width: 2, height: 1, pixels: px)
  let enc = encodeHdr(img) # width 2 -> flat path
  let dec = decodeHdr(enc)
  check dec.ok
  check dec.value.width == 2
  check dec.value.height == 1
  check dec.value.pixels[0].data == px[0].data
  check dec.value.pixels[1].data == px[1].data

test "hdr RLE round-trip":
  var px = newSeq[Rgb[float32]](16)
  for i in 0..<16: px[i] = Rgb[float32](data: [1.0'f32, 1.0, 1.0])
  let img = Rgb32FImage(width: 8, height: 2, pixels: px)
  let enc = encodeHdr(img) # width 8 -> RLE path
  let dec = decodeHdr(enc)
  check dec.ok
  check dec.value.pixels.len == 16
  for p in dec.value.pixels:
    check p.data == [1.0'f32, 1.0, 1.0]

test "hdr bad signature":
  check decodeHdr(@[uint8('P'), uint8('6')]).ok == false

test "hdr unsupported orientation":
  let s = "#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n+Y 1 +X 1\n"
  var data = newSeq[uint8](s.len + 4)
  for i, c in s: data[i] = uint8(c)
  check decodeHdr(data).ok == false
