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
  # Also covers the decoder peek-ahead path (back-to-back cache hits
  # after long codes) and the LZ77 copy path at scale.
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

test "webp vp8l lz77 flat image tiny":
  # Single color with alpha: first pixel literal, the rest one d==1 run.
  var px = newSeq[Rgba[uint8]](64 * 64)
  for i in 0..<px.len:
    px[i] = Rgba[uint8](data: [10'u8, 20, 30, 128])
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 64, height: 64, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  check enc.value.len < 1024
  let dec = decodeWebp(enc.value)
  check dec.ok
  require dec.value.kind == dkRgba8
  check dec.value.rgba8.pixels == px

test "webp vp8l lz77 periodic stripes":
  # 8-color cycle: cache hits plus short d==8 copies. Opaque in, Rgb8 out.
  var px = newSeq[Rgba[uint8]](128 * 8)
  for i in 0..<px.len:
    let v = uint8((i mod 8) * 32)
    px[i] = Rgba[uint8](data: [v, v, v, 255])
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 128, height: 8, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  check enc.value.len < 2048
  let dec = decodeWebp(enc.value)
  check dec.ok
  require dec.value.kind == dkRgb8
  for i, p in dec.value.rgb8.pixels:
    check [p.data[0], p.data[1], p.data[2]] ==
      [px[i].data[0], px[i].data[1], px[i].data[2]]

test "webp vp8l noise round-trips without matches":
  # 1024 distinct opaque pixels (unique R,G pairs): no hits or copies
  # possible, exercising the literal path plus the dummy single-symbol
  # dist tree. Opaque -> Rgb8.
  var px = newSeq[Rgba[uint8]](32 * 32)
  for i in 0..<px.len:
    px[i] = Rgba[uint8](data: [uint8(i and 255), uint8((i shr 8) and 255),
      uint8((i * 131 + 17) and 255), 255'u8])
  var seen = newSeq[bool](1 shl 16)
  for p in px:
    let k = int(p.data[0]) or (int(p.data[1]) shl 8)
    check not seen[k] # test premise: all pixels distinct
    seen[k] = true
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 32, height: 32, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  let dec = decodeWebp(enc.value)
  check dec.ok
  require dec.value.kind == dkRgb8
  for i, p in dec.value.rgb8.pixels:
    check [p.data[0], p.data[1], p.data[2]] ==
      [px[i].data[0], px[i].data[1], px[i].data[2]]

test "webp vp8l predictor tames gradients":
  # Smooth gradients defeat LZ77 (no exact repeats); the predictor
  # transform reduces them to near-zero residuals. 64x64 gradient in
  # 84 bytes, pixel-exact (was ~12 KB literal).
  var px = newSeq[Rgba[uint8]](64 * 64)
  for y in 0..<64:
    for x in 0..<64:
      px[y * 64 + x] = Rgba[uint8](data: [uint8(x mod 256),
        uint8(y mod 256), uint8((x + y) mod 256), 255])
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 64, height: 64, pixels: px))
  let enc = encodeWebp(img)
  check enc.ok
  check enc.value.len < 512
  let back = decodeWebp(enc.value)
  check back.ok
  require back.value.kind == dkRgb8
  for i, p in back.value.rgb8.pixels:
    check [p.data[0], p.data[1], p.data[2]] ==
      [px[i].data[0], px[i].data[1], px[i].data[2]]

test "webp vp8l length prefix codes round-trip":
  # lengthSymExtra must invert copyDist for every length 1..4096.
  proc fwdCopyDist(prefix, extra: int): int =
    if prefix < 4: return prefix + 1
    let e = (prefix - 2) shr 1
    let off = (2 + (prefix and 1)) shl e
    off + extra + 1
  for L in 1..4096:
    let (sym, extra, nbits) = lengthSymExtra(L)
    check sym >= 0 and sym <= 23
    check extra >= 0 and extra < (1 shl nbits)
    check fwdCopyDist(sym, extra) == L

test "webp vp8l dist choice smoke":
  # Hand-verified against DistMap: d=1 -> prefix 1 (no extra bits);
  # d=2 at width 64 -> prefix 4 (DM[5]=(2,0)). Prefixes < 4 must carry
  # extra value 0 (decoder reads zero extra bits there; a nonzero value
  # would corrupt the bit buffer).
  var dc: array[40, int]
  for k in 0..39: dc[k] = 0
  let (s1, e1, ok1) = distChoice(1, 64, dc)
  check ok1
  check s1 == 1
  check e1 == 0
  let (s2, e2, ok2) = distChoice(2, 64, dc)
  check ok2
  check s2 == 4
  check e2 == 1
  check distChoice(0, 64, dc).ok == false
  check distChoice(1048456 + 1, 64, dc).ok == false
