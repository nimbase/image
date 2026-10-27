## Decode/encode throughput harness (plan 7.3): PNG + JPEG MB/s.
## Not part of `clue test`. Run with:
##   clue build benches/decode.nim --release -o:/tmp/imgbench && /tmp/imgbench [iters]
## Uses std/monotimes only (no criterion dep).
import std/times
import std/strformat
import std/strutils
import std/os
import image

proc mbps(bytes: int, dt: float64): float64 =
  float64(bytes) / dt / 1e6

proc benchPng(px: seq[Rgb[uint8]], w, h, iters: int) =
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: px))
  let enc = encodePng(img).value
  var t0 = cpuTime()
  for _ in 0..<iters:
    let dec = decodePng(enc)
    doAssert dec.ok
  var dt = cpuTime() - t0
  echo fmt"png  decode {enc.len} bytes {w}x{h}: {mbps(enc.len * iters, dt):.1f} MB/s"
  t0 = cpuTime()
  for _ in 0..<iters:
    let e2 = encodePng(img)
    doAssert e2.ok
  dt = cpuTime() - t0
  echo fmt"png  encode {w}x{h}: {mbps(w * h * 3 * iters, dt):.1f} MB/s (raw px)"

proc benchJpeg(px: seq[Rgb[uint8]], w, h, iters: int) =
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: px))
  let enc = encodeJpeg(img, 90).value
  var t0 = cpuTime()
  for _ in 0..<iters:
    let dec = decodeJpeg(enc)
    doAssert dec.ok
  var dt = cpuTime() - t0
  echo fmt"jpeg decode {enc.len} bytes {w}x{h}: {mbps(enc.len * iters, dt):.1f} MB/s"
  t0 = cpuTime()
  for _ in 0..<iters:
    let e2 = encodeJpeg(img, 90)
    doAssert e2.ok
  dt = cpuTime() - t0
  echo fmt"jpeg encode {w}x{h}: {mbps(w * h * 3 * iters, dt):.1f} MB/s (raw px)"

when isMainModule:
  let iters = if paramCount() >= 1: parseInt(paramStr(1)) else: 5
  let w = 1920; let h = 1080
  var px = newSeq[Rgb[uint8]](w * h)
  for y in 0..<h:
    for x in 0..<w:
      px[y * w + x] = Rgb[uint8](data: [
        uint8((x * 255) div w), uint8((y * 255) div h),
        uint8(((x + y) * 255) div (w + h))])
  benchPng(px, w, h, iters)
  benchJpeg(px, w, h, iters)
