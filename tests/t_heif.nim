## HEIF tests: P0 container/item parse, P1 uncompressed, P2 JPEG-in-HEIF,
## P3 video/J2K clean Unsupported. Decode fixtures validated against
## `heif-convert` oracle sums (see plans/09-heif.md); the JPEG case asserts
## container transparency (decodeHeif == decodeJpeg on the same bytes) since
## JPEG IDCT rounding is decoder-defined.
import unittest
import std/os
import image
import image/codecs/heif/heif
import image/codecs/jpgdec

let fixturesDir = currentSourcePath().parentDir() / "fixtures" / "heif"

proc readRaw(p: string): seq[uint8] =
  var f = open(p, fmRead)
  result = newSeq[uint8](getFileSize(f))
  discard readBytes(f, result, 0, result.len)
  close(f)

proc pixelSum(img: DynamicImage): uint64 =
  case img.kind
  of dkRgb8:
    for px in img.rgb8.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
  of dkRgba8:
    for px in img.rgba8.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) +
        uint64(px.data[2]) + uint64(px.data[3])
  of dkLuma8:
    for px in img.luma8.pixels: result += uint64(px.data[0])
  of dkRgb16:
    for px in img.rgb16.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
  of dkRgba16:
    for px in img.rgba16.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) +
        uint64(px.data[2]) + uint64(px.data[3])
  of dkLuma16:
    for px in img.luma16.pixels: result += uint64(px.data[0])
  else:
    doAssert false, "unexpected kind"

test "heif uncompressed v1 rgb":
  for name in ["unc-rgb-64x48.heif", "unc-rgb-zlib-64x48.heif"]:
    let dec = decodeHeif(readRaw(fixturesDir / name))
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (64'u32, 48'u32)
    check pixelSum(dec.value) == 1159344'u64

test "heif uncompressed v1 mono+rgba":
  let m = decodeHeif(readRaw(fixturesDir / "unc-mono-64x48.heif"))
  check m.ok
  check m.value.kind == dkLuma8
  check m.value.dimensions() == (64'u32, 48'u32)
  check pixelSum(m.value) == 381770'u64
  let a = decodeHeif(readRaw(fixturesDir / "unc-rgba-64x48.heif"))
  check a.ok
  check a.value.kind == dkRgba8
  check a.value.dimensions() == (64'u32, 48'u32)
  check pixelSum(a.value) == 1952604'u64

test "heif uncompressed v0 component rgb":
  let dec = decodeHeif(readRaw(fixturesDir / "unc-comp-rgb-30x20.heif"))
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (30'u32, 20'u32)
  check pixelSum(dec.value) == 233528'u64

test "heif uncompressed v0 yuv420":
  # YUV->RGB rounding is implementation-defined (nclx pins no rounding);
  # allow small tolerance vs the libheif oracle sum.
  for name in ["unc-comp-yuv420-32x20.heif", "unc-mix-yuv420-32x20.heif",
      "unc-comp-yvu420-32x20.heif", "unc-comp-vuy420-32x20.heif",
      "unc-mix-yvu420-32x20.heif", "unc-mix-vuy420-32x20.heif"]:
    let dec = decodeHeif(readRaw(fixturesDir / name))
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (32'u32, 20'u32)
    let s = pixelSum(dec.value)
    check abs(int64(s) - 246768) < 2000

test "heif uncompressed v0 yuv422":
  for name in ["unc-comp-yuv422-32x20.heif", "unc-mix-yuv422-32x20.heif"]:
    let dec = decodeHeif(readRaw(fixturesDir / name))
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (32'u32, 20'u32)
    let s = pixelSum(dec.value)
    check abs(int64(s) - 246768) < 2000

test "heif uncompressed v0 pixel layouts":
  let r = decodeHeif(readRaw(fixturesDir / "unc-pix-rgb-30x20.heif"))
  check r.ok
  check r.value.kind == dkRgb8
  check pixelSum(r.value) == 233528'u64
  let m = decodeHeif(readRaw(fixturesDir / "unc-pix-mono-30x20.heif"))
  check m.ok
  check m.value.kind == dkLuma8
  check pixelSum(m.value) == 79936'u64
  let a = decodeHeif(readRaw(fixturesDir / "unc-pix-abgr-30x20.heif"))
  check a.ok
  check a.value.kind == dkRgba8
  check pixelSum(a.value) == 313598'u64
  let x = decodeHeif(readRaw(fixturesDir / "unc-pix-rgxb-30x20.heif"))
  check x.ok
  check x.value.kind == dkRgb8
  check pixelSum(x.value) == 233528'u64

test "heif uncompressed v0 component abgr+mono":
  let a = decodeHeif(readRaw(fixturesDir / "unc-comp-abgr-30x20.heif"))
  check a.ok
  check a.value.kind == dkRgba8
  check pixelSum(a.value) == 313598'u64
  let m = decodeHeif(readRaw(fixturesDir / "unc-comp-mono-30x20.heif"))
  check m.ok
  check m.value.kind == dkLuma8
  check pixelSum(m.value) == 79936'u64

test "heif uncompressed v0 row interleave":
  let r = decodeHeif(readRaw(fixturesDir / "unc-row-rgb-30x20.heif"))
  check r.ok
  check r.value.kind == dkRgb8
  check pixelSum(r.value) == 233528'u64
  let m = decodeHeif(readRaw(fixturesDir / "unc-row-mono-30x20.heif"))
  check m.ok
  check m.value.kind == dkLuma8
  check pixelSum(m.value) == 79936'u64
  let a = decodeHeif(readRaw(fixturesDir / "unc-row-abgr-30x20.heif"))
  check a.ok
  check a.value.kind == dkRgba8
  check pixelSum(a.value) == 313598'u64

test "heif uncompressed 16-bit":
  let dec = decodeHeif(readRaw(fixturesDir / "unc-pix-b16-30x20.heif"))
  check dec.ok
  check dec.value.kind == dkRgb16
  check dec.value.dimensions() == (30'u32, 20'u32)
  check pixelSum(dec.value) == 60016696'u64

test "heif jpeg in heif is transparent":
  let raw = readRaw(fixturesDir / "jpeg-64x48.heif")
  let viaHeif = decodeHeif(raw)
  check viaHeif.ok
  check viaHeif.value.kind == dkRgb8
  check viaHeif.value.dimensions() == (64'u32, 48'u32)
  let bytes = extractItemBytes(raw)
  check bytes.ok
  let direct = decodeJpeg(bytes.value)
  check direct.ok
  check pixelSum(viaHeif.value) == pixelSum(direct.value)

test "heif video and j2k unsupported":
  for name in ["hevc-64x48.heif", "hevc-rainbow-451x461.heic",
      "hevc-alpha-512x512.heic", "j2k-64x48.heif"]:
    check decodeHeif(readRaw(fixturesDir / name)).ok == false

test "heif j2k codestream extraction":
  let raw = readRaw(fixturesDir / "j2k-64x48.heif")
  let ex = extractJ2kCodestream(raw)
  check ex.ok
  check ex.value.len > 100
  # non-J2K primary refuses extraction
  check extractJ2kCodestream(
    readRaw(fixturesDir / "jpeg-64x48.heif")).ok == false

test "heif truncated fails cleanly":
  for name in ["unc-rgb-64x48.heif", "jpeg-64x48.heif", "hevc-64x48.heif"]:
    let raw = readRaw(fixturesDir / name)
    for c in [0, 1, 11, 12, 27, raw.len div 2, raw.len - 1]:
      check decodeHeif(raw[0 ..< c]).ok == false
