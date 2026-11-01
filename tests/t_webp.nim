import unittest
import std/os
import std/strutils
import image
import image/codecs/jpeg
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

test "webp vp8l leading repeat run":
  # Regression: channels whose code lengths open with a run of >=3 equal
  # nonzero lengths used to emit code 16 ("repeat previous") against the
  # decoder's initial prev of 8, rebuilding a different tree ("bad image
  # data"). Smooth gradients hit this constantly.
  var px = @[Rgba[uint8](data: [0'u8, 0, 0, 255]),
    Rgba[uint8](data: [1'u8, 2, 3, 255]),
    Rgba[uint8](data: [2'u8, 4, 6, 255]),
    Rgba[uint8](data: [3'u8, 6, 9, 255])]
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 2, height: 2, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  let dec = decodeWebp(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  for i, p in dec.value.rgb8.pixels:
    check [p.data[0], p.data[1], p.data[2]] ==
      [px[i].data[0], px[i].data[1], px[i].data[2]]

test "webp vp8l lengths respect cap and Kraft":
  # Regression: photo histograms push Huffman depths past 15 (and the
  # 3-bit code-length code past 7); lengths must stay capped and the
  # code complete, or real photos fail with "bad image data".
  proc kraftOk(lens: seq[uint16], cap: int): bool =
    var maxL = 0
    var n = 0
    for l in lens:
      if l != 0:
        inc n
        if int(l) > maxL: maxL = int(l)
    if n <= 1: return true # decoder single-symbol special case
    if maxL == 0 or maxL > cap: return false
    var code = 0
    var hist = newSeq[int](maxL + 1)
    for l in lens:
      if l != 0: hist[int(l)] += 1
    for l in 1..maxL:
      code = (code + hist[l]) shl 1
    code == 2 shl maxL
  # Fibonacci-skewed counts force deep trees; 280 symbols at cap 15
  # (literal alphabets) and 19 symbols at cap 7 (the RLE code itself).
  var fib280 = newSeq[int](280)
  var fib19 = newSeq[int](19)
  var a = 1
  var b = 1
  for i in 0..<280:
    if i < 19: fib19[i] = a
    fib280[i] = a
    let n = a + b
    a = b
    b = min(n, 1 shl 30)
  check kraftOk(buildLens(fib280, 15), 15)
  check kraftOk(buildLens(fib19, 7), 7)
  # single-symbol and empty inputs stay well-formed
  var one = newSeq[int](256)
  one[42] = 999
  let l1 = buildLens(one)
  check l1[42] == 1
  check kraftOk(@[1'u16], 15)

test "webp vp8l photo content round-trips":
  # Regression: photo crops (deep, skewed histograms) used to emit
  # undecodable streams. Pixel-exact via the lossless path.
  let p = fixturesDir / "pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  let d = decodeJpeg(raw)
  require d.ok
  let c = cropImage(d.value, 100, 100, 1100, 1100)
  require c.ok
  let rgba = c.value.toRgba8()
  let e = encodeWebp(DynamicImage(kind: dkRgba8, rgba8: rgba))
  require e.ok
  let back = decodeWebp(e.value)
  require back.ok
  check back.value.dimensions() == (1100'u32, 1100'u32)
  require back.value.kind == dkRgba8 or back.value.kind == dkRgb8
  if back.value.kind == dkRgba8:
    check back.value.rgba8.pixels == rgba.pixels
  else:
    for i, px in back.value.rgb8.pixels:
      check [px.data[0], px.data[1], px.data[2]] ==
        [rgba.pixels[i].data[0], rgba.pixels[i].data[1], rgba.pixels[i].data[2]]
  check decodeWebp(@[0'u8, 1, 2, 3]).ok == false
