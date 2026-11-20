import unittest
import std/os
import image
import image/codecs/jpeg

let fixturesDir = currentSourcePath().parentDir() / "fixtures"

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
  let p = fixturesDir / "jpg" / "iptc.jpg"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  let dec = decodeJpeg(raw)
  check dec.ok
  check dec.value.dimensions() == (64'u32, 48'u32)

test "jpeg progressive":
  # 4:2:0 single-component scans visit blocks in raster order (one block
  # per MCU); pixel sums below were validated against djpeg -nosmooth
  # (maxdiff <= 2, integer-IDCT rounding).
  for (name, w, h, sum) in [("test.jpg", 32'u32, 23'u32, 325358'u64),
      ("cat.jpg", 320'u32, 240'u32, 31389477'u64),
      ("3.jpg", 650'u32, 470'u32, 116985225'u64)]:
    let p = fixturesDir / "jpg" / "progressive" / name
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeJpeg(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (w, h)
    var s = 0'u64
    for px in dec.value.rgb8.pixels:
      s += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
    check s == sum

test "jpeg progressive trimmed padding tail":
  # Non-interleaved progressive scans use the component's visible block
  # grid (libjpeg-turbo jcmaster.c per_scan_setup: width_in_blocks x
  # height_in_blocks), which can be one block narrower/shorter than the
  # MCU-padded coefficient grid. These cjpeg fixtures also cover the
  # MCU block-tile split for non-square sampling (4:2:2 / 4:4:0): the
  # tile row is `b div h`, not `b div v` (those coincide only at 4:2:0).
  # 32x23 4:2:0 has 3 visible Y block rows (12 blocks) vs 4 padded;
  # 17x23 has a padding column (4:2:2) or row (4:4:0). Sums validated
  # against djpeg -nosmooth (maxdiff <= 3).
  for (name, w, h, sum) in [
      ("pad-trim.jpg", 32'u32, 23'u32, 301492'u64),
      ("pad-trim-422.jpg", 17'u32, 23'u32, 160524'u64),
      ("pad-trim-440.jpg", 17'u32, 23'u32, 160135'u64)]:
    let p = fixturesDir / "jpg" / "progressive" / name
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeJpeg(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (w, h)
    var s = 0'u64
    for px in dec.value.rgb8.pixels:
      s += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
    check s == sum
    # Truncating real pixels (mid-scan) must still fail.
    check decodeJpeg(raw[0 ..< raw.len div 2]).ok == false

test "jpeg bad data":
  check decodeJpeg(@[0xFF'u8, 0xD8, 0xFF, 0x00]).ok == false
  check decodeJpeg(@[0'u8, 1]).ok == false

test "jpeg scratch reuse is bit-identical":
  # Phase 2 S1: a long-lived JpegScratch must decode exactly what a
  # fresh buffer decodes, while retaining capacity across calls.
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  proc rgbSum(d: DynamicImage): uint64 =
    for px in d.rgb8.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
  let small = readRaw(fixturesDir / "jpg" / "progressive" / "pad-trim.jpg")
  let big = readRaw(fixturesDir / "pexels-shahin-mren-92379627-29895390.jpg")
  var scratch = initJpegScratch()
  # Fresh vs scratch agree on both sizes, both denoms.
  check rgbSum(decodeJpeg(small).value) == 301492'u64
  check rgbSum(decodeJpeg(small, scratch).value) == 301492'u64
  check rgbSum(decodeJpeg(small, scratch, 2).value) ==
    rgbSum(decodeJpeg(small, 2).value)
  # Large photo through the same scratch: identical pixels, and the
  # pool grew to hold its largest scan.
  let bigSum = rgbSum(decodeJpeg(big).value)
  check rgbSum(decodeJpeg(big, scratch).value) == bigSum
  let cap1 = scratch.clean.data.len
  check cap1 > 1_000_000 # largest entropy scan of a 32 MP photo
  check rgbSum(decodeJpeg(big, scratch).value) == bigSum
  # Small again after large: still identical, and the header is
  # trimmed back to the small scan (exactness matters: the BitReader
  # bounds on data.len, so stale bytes must never linger in length).
  check rgbSum(decodeJpeg(small, scratch).value) == 301492'u64
  check scratch.clean.data.len < cap1
  # shrinkAfterSpike drops the peak; decoding still works after.
  shrinkAfterSpike(scratch, 1024)
  check scratch.clean.data.len == 1024
  check rgbSum(decodeJpeg(small, scratch).value) == 301492'u64
  # Truncation still fails through the scratch overload.
  check decodeJpeg(small[0 ..< small.len div 2], scratch).ok == false


proc boxDown(px: seq[Rgb[uint8]], w, h, d: int): seq[Rgb[uint8]] =
  let w2 = (w + d - 1) div d
  let h2 = (h + d - 1) div d
  result = newSeq[Rgb[uint8]](w2 * h2)
  for y in 0..<h2:
    for x in 0..<w2:
      var sr, sg, sb = 0
      for dy in 0..<d:
        for dx in 0..<d:
          let p = px[min(y*d+dy, h-1) * w + min(x*d+dx, w-1)]
          sr += int(p.data[0]); sg += int(p.data[1]); sb += int(p.data[2])
      let n = d * d
      result[y*w2+x] = Rgb[uint8](data: [uint8((sr+n div 2) div n),
        uint8((sg+n div 2) div n), uint8((sb+n div 2) div n)])

test "jpeg scaled dims and denom validation":
  var px = newSeq[Rgb[uint8]](16 * 16)
  for i in 0..<px.len:
    px[i] = Rgb[uint8](data: [uint8(i and 0xFF), uint8((i*2) and 0xFF),
      uint8((i*3) and 0xFF)])
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 16, height: 16, pixels: px))
  let enc = encodeJpeg(img, 90)
  check enc.ok
  for (d, w, h) in [(1, 16'u32, 16'u32), (2, 8'u32, 8'u32),
      (4, 4'u32, 4'u32), (8, 2'u32, 2'u32)]:
    let dec = decodeJpeg(enc.value, d)
    check dec.ok
    check dec.value.dimensions() == (w, h)
  check decodeJpeg(enc.value, 3).ok == false
  check decodeJpeg(enc.value, 0).ok == false
  # ceil dims on non-multiples
  var px2 = newSeq[Rgb[uint8]](20 * 12)
  for i in 0..<px2.len:
    px2[i] = Rgb[uint8](data: [128'u8, 64, 32])
  let img2 = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 20, height: 12, pixels: px2))
  let enc2 = encodeJpeg(img2, 90)
  check enc2.ok
  check decodeJpeg(enc2.value, 2).value.dimensions() == (10'u32, 6'u32)
  check decodeJpeg(enc2.value, 8).value.dimensions() == (3'u32, 2'u32)

test "jpeg scaled gray bit-exact vs box":
  # single component: box-in-block == box-on-pixels, identical rounding
  var px = newSeq[Luma[uint8]](32 * 32)
  for y in 0..<32:
    for x in 0..<32:
      px[y*32+x] = Luma[uint8](data: [uint8((x*3 + y*5) and 0xFF)])
  let img = DynamicImage(kind: dkLuma8,
    luma8: GrayImage(width: 32, height: 32, pixels: px))
  let enc = encodeJpeg(img, 90)
  check enc.ok
  let full = decodeJpeg(enc.value).value.luma8
  for d in [2, 4, 8]:
    let s = decodeJpeg(enc.value, d)
    check s.ok
    check s.value.kind == dkLuma8
    let w2 = (32 + d - 1) div d
    for y in 0..<(32 + d - 1) div d:
      for x in 0..<w2:
        var acc = 0
        for dy in 0..<d:
          for dx in 0..<d:
            acc += int(full.pixels[min(y*d+dy, 31) * 32 + min(x*d+dx, 31)].data[0])
        check s.value.luma8.pixels[y*w2+x].data[0] ==
          uint8((acc + d*d div 2) div (d*d))

test "jpeg scaled 444 close to box":
  # 4:4:4: component space == pixel space; residual is float
  # rounding order only (measured maxDiff 2 on smooth content).
  var px = newSeq[Rgb[uint8]](64 * 64)
  for y in 0..<64:
    for x in 0..<64:
      px[y*64+x] = Rgb[uint8](data: [uint8((x*3+y) and 0xFF),
        uint8((y*4+128) and 0xFF), uint8((x+y*2+64) and 0xFF)])
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 64, height: 64, pixels: px))
  let enc = encodeJpeg(img, 90, subsample = false)
  check enc.ok
  let full = decodeJpeg(enc.value).value.toRgb8()
  for d in [2, 4, 8]:
    let s = decodeJpeg(enc.value, d).value.toRgb8()
    let refBox = boxDown(full.pixels, 64, 64, d)
    check s.pixels.len == refBox.len
    var md = 0
    for i in 0..<s.pixels.len:
      for k in 0..2:
        md = max(md, abs(int(s.pixels[i].data[k]) - int(refBox[i].data[k])))
    check md <= 4

test "jpeg scaled 420 sane vs box":
  # 4:2:0: box happens in subsampled chroma space (wider effective
  # filter than box-on-RGB); bounds measured on smooth content
  # (5/10/16 for denom 2/4/8). Exact reduced-IDCT matching is step 2.
  var px = newSeq[Rgb[uint8]](64 * 64)
  for y in 0..<64:
    for x in 0..<64:
      px[y*64+x] = Rgb[uint8](data: [uint8((x*3+y) and 0xFF),
        uint8((y*4+128) and 0xFF), uint8((x+y*2+64) and 0xFF)])
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 64, height: 64, pixels: px))
  let enc = encodeJpeg(img, 90)
  check enc.ok
  let full = decodeJpeg(enc.value).value.toRgb8()
  for (d, bound) in [(2, 8), (4, 16), (8, 24)]:
    let s = decodeJpeg(enc.value, d).value.toRgb8()
    let refBox = boxDown(full.pixels, 64, 64, d)
    var md = 0
    for i in 0..<s.pixels.len:
      for k in 0..2:
        md = max(md, abs(int(s.pixels[i].data[k]) - int(refBox[i].data[k])))
    check md <= bound

test "jpeg dimensions header scan":
  let p = fixturesDir / "jpg" / "iptc.jpg"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  let dims = jpegDimensions(raw)
  check dims.ok
  check dims.value == (64'u32, 48'u32)
  check jpegDimensions(@[0xFF'u8, 0xD8, 0xFF, 0x00]).ok == false
  check jpegDimensions(@[0'u8, 1]).ok == false
