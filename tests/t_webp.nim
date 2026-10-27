import unittest
import std/os
import std/strutils
import image
import image/codecs/webp

let fixturesDir = currentSourcePath().parentDir() / "fixtures"

test "webp vp8l round-trip":
  var px = newSeq[Rgba[uint8]](16)
  for i in 0..<16:
    px[i] = Rgba[uint8](data: [uint8(i*16), uint8(255 - i*8), uint8(i*3), 255'u8])
  let img = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 4, height: 4, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  check enc.value[0] == uint8('R')
  let dec = decodeWebp(enc.value)
  check dec.ok
  # all-opaque strips alpha like the reference decoder
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (4'u32, 4'u32)
  for i, p in dec.value.rgb8.pixels:
    check [p.data[0], p.data[1], p.data[2]] == [px[i].data[0], px[i].data[1], px[i].data[2]]

test "webp vp8l round-trip with alpha":
  var px = @[Rgba[uint8](data: [10'u8, 20, 30, 0]), Rgba[uint8](data: [40'u8, 50, 60, 128]),
             Rgba[uint8](data: [70'u8, 80, 90, 200]), Rgba[uint8](data: [1'u8, 2, 3, 255])]
  let img = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 2, height: 2, pixels: px))
  let dec = decodeWebp(encodeWebp(img).value)
  check dec.ok
  check dec.value.kind == dkRgba8
  check dec.value.rgba8.pixels == px

test "webp reference lossless":
  let dir = fixturesDir / "webp" / "lossless_images"
  var count = 0
  for kind, p in walkDir(dir):
    if not p.endsWith(".webp"): continue
    if p.contains("xmp"): continue # covered separately; XMP chunk skipped
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeWebp(raw)
    check dec.ok
    check dec.value.dimensions() == (300'u32, 300'u32)
    inc(count)
  check count == 3

test "webp lossy vp8":
  # pixel sums validated bit-exact against dwebp (fancy upsampling)
  for (name, w, h, sum) in [("simple-rgb.webp", 100'u32, 100'u32, 2623385'u64),
      ("simple-gray.webp", 100'u32, 100'u32, 3664880'u64),
      ("odd-101x57-q80.webp", 101'u32, 57'u32, 2164248'u64),
      ("photo-640x427-q75.webp", 640'u32, 427'u32, 74437231'u64)]:
    let p = fixturesDir / "webp" / "lossy_images" / name
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeWebp(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (w, h)
    var s = 0'u64
    for px in dec.value.rgb8.pixels:
      s += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
    check s == sum

test "webp lossy truncated":
  let p = fixturesDir / "webp" / "lossy_images" / "simple-rgb.webp"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  # any truncation must fail cleanly (bool-decoder EOF paths), never raise
  for c in [0, 1, 2, raw.len div 2, raw.len - 1]:
    check decodeWebp(raw[0..<c]).ok == false

test "webp lossy alpha unsupported":
  # VP8X + ALPH needs alpha compositing (follow-up); must fail cleanly
  let p = fixturesDir / "webp" / "extended_images" / "lossy_alpha.webp"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  check decodeWebp(raw).ok == false

test "webp bad riff":
  check decodeWebp(@[0'u8, 1, 2, 3]).ok == false
