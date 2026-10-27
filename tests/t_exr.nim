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

test "exr bad magic":
  check decodeExr(@[0'u8, 1, 2, 3]).ok == false
