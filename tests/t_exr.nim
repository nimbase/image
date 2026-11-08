import unittest
import std/os
import std/strutils
import image
import image/codecs/openexr

let fixturesDir = currentSourcePath().parentDir() / "fixtures"

test "half conversions":
  check halfToFloat(0x0000'u16) == 0.0f32
  check halfToFloat(0x3C00'u16) == 1.0f32
  check halfToFloat(0xBC00'u16) == -1.0f32
  check halfToFloat(0x7C00'u16) == Inf.float32
  check floatToHalf(1.0f32) == 0x3C00'u16
  check floatToHalf(0.0f32) == 0x0000'u16
  check floatToHalf(-0.0f32) == 0x8000'u16
  check floatToHalf(65504.0f32) == 0x7BFF'u16
  # round-trip of a normal value
  check halfToFloat(floatToHalf(0.33325195f32)) == halfToFloat(0x3555'u16)
  # round-to-nearest-even (truncation gives 0xD16A/0xBCFE here instead)
  check floatToHalf(-43.333332f32) == 0xD16B'u16
  check floatToHalf(0.33333334f32) == 0x3555'u16
  check floatToHalf(65504.0f32) == 0x7BFF'u16

test "exr rgb32f round-trip (ZIP)":
  var px = @[Rgb[float32](data: [1.0f32, 0.5, 0.25]),
             Rgb[float32](data: [-2.0f32, 100.0, 0.0])]
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 2, height: 1, pixels: px))
  let enc = encodeExr(img)
  check enc.ok
  check enc.value[0] == 0x76 and enc.value[1] == 0x2F
  let dec = decodeExr(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb32F
  check dec.value.rgb32f.pixels == px

test "exr luma32f round-trip":
  var px = @[Luma[float32](data: [3.25f32])]
  let img = DynamicImage(kind: dkLuma32F, luma32f: Gray32FImage(width: 1, height: 1, pixels: px))
  let dec = decodeExr(encodeExr(img).value)
  check dec.ok
  check dec.value.luma32f.pixels == px

test "exr reference RLE":
  let dir = fixturesDir / "exr"
  var foundUncropped = false
  var foundCropped = false
  for kind, p in walkDir(dir):
    if not p.endsWith(".exr"): continue
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeExr(raw)
    if p.contains("uncropped"):
      foundUncropped = true
      check dec.ok
      check dec.value.kind == dkRgba32F
      check dec.value.dimensions() == (1920'u32, 1920'u32)
      # pixel-content lock vs the reference decoder (5498 nonzero,
      # channel sum 11670.322387271794): guards the biased RLE predictor
      # and planar layout, which dimensions alone cannot catch.
      var nz = 0
      var sum = 0.0'f64
      for q in dec.value.rgba32f.pixels:
        if q.data[0] != 0 or q.data[1] != 0 or q.data[2] != 0: inc nz
        sum += q.data[0].float64 + q.data[1].float64 +
          q.data[2].float64 + q.data[3].float64
      check nz == 5498
      check abs(sum - 11670.322387271794'f64) < 1e-6
    elif p.contains("differs"):
      foundCropped = true
      check dec.ok
      check dec.value.kind == dkRgba32F
      # data window 1012..1326 x 1097..1196
      check dec.value.dimensions() == (315'u32, 100'u32)
  check foundUncropped and foundCropped

test "exr PIZ unsupported":
  let p = fixturesDir / "exr" / "overexposed gradient - data window equals display window.exr"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  check decodeExr(raw).ok == false

test "exr pxr24 round-trip within spec error":
  # PXR24 rounds float channels to 24 bits (spec: rel err ~3e-5).
  var px = @[
    Rgb[float32](data: [1.0f32, 0.5f32, -0.25f32]),
    Rgb[float32](data: [100.0f32, -2.0f32, 0.0f32]),
    Rgb[float32](data: [1.0f32/3.0f32, 65504.0f32, 1e-7f32]),
    Rgb[float32](data: [Inf.float32, 0.0f32, -0.0f32])]
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 4, height: 1, pixels: px))
  let enc = encodeExr(img, 5)
  check enc.ok
  check enc.value[0] == 0x76 and enc.value[1] == 0x2F
  let dec = decodeExr(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb32F
  for i, p in dec.value.rgb32f.pixels:
    for c in 0..2:
      let a = px[i].data[c]
      let b = p.data[c]
      if a != a or a == Inf.float32 or a == -Inf.float32:
        check b == a
      elif a == 0.0f32:
        check b == 0.0f32
      else:
        check abs(b - a) / abs(a) <= 3e-5f32

test "exr pxr24 official reference decodes bit-exact":
  # Fixtures written directly with the reference library (OpenEXR 3.4.12
  # C++ API, no CLI in the loop) from a 16x16 float gradient: the float
  # file must decode bit-identical to the reference lib's own PXR24->NONE
  # conversion of the same pixels (standard conformance: exact vs
  # reference decoder output, not vs pre-lossy original). NOTE: do not
  # mint these with `exrmetrics --convert` — its ZIP/RLE->PXR24 transcode
  # path emits non-planar chunks the reference decoder itself misreads.
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  let a = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-float.exr"))
  let b = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-float-none.exr"))
  check a.ok and b.ok
  check a.value.kind == dkRgb32F and b.value.kind == dkRgb32F
  check a.value.rgb32f.pixels == b.value.rgb32f.pixels
  # half channels survive PXR24 exactly: expected = half-rounded source
  let h = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-half.exr"))
  check h.ok
  check h.value.kind == dkRgb32F
  for y in 0..<16:
    for x in 0..<16:
      let fx = float32(x) / 15.0f32
      let fy = float32(y) / 15.0f32
      let src = [fx*100.0f32 - 50.0f32, fy*2.0f32 - 1.0f32, (fx+fy)*0.5f32]
      let got = h.value.rgb32f.pixels[y*16+x].data
      if x == 0 and y == 0:
        check got[0] == halfToFloat(floatToHalf(65504.0f32))
        check got[1] == halfToFloat(floatToHalf(-65504.0f32))
        check got[2] == halfToFloat(floatToHalf(1e-7f32))
      else:
        for c in 0..2:
          check got[c] == halfToFloat(floatToHalf(src[c]))

test "exr foreign lossless files decode bit-exact":
  # Same lib-minted pixels under NONE/RLE/ZIPS/ZIP must all decode to
  # identical pixels (covers the planar-per-scanline disk layout and the
  # biased ZIP/RLE predictor against foreign bytes, not just our own).
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  var refPx: seq[Rgb[float32]] = @[]
  for i, name in ["pxr24-lib-none.exr", "rle-lib-reference.exr",
      "zips-lib-reference.exr", "zip-lib-reference.exr"]:
    let d = decodeExr(readRaw(fixturesDir / "exr" / name))
    check d.ok
    check d.value.kind == dkRgb32F
    check d.value.dimensions() == (16'u32, 16'u32)
    if i == 0: refPx = d.value.rgb32f.pixels
    else: check d.value.rgb32f.pixels == refPx
  # anchor against the known source gradient (px0 extremes + a mid pixel)
  check refPx[0].data == [65504.0f32, -65504.0f32, 1e-7f32]
  let fx = float32(10) / 15.0f32
  check refPx[10].data[0] == fx*100.0f32 - 50.0f32
  check refPx[10].data[1] == -1.0f32

test "exr bad magic":
  check decodeExr(@[0'u8, 1, 2, 3]).ok == false
