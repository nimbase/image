import unittest
import std/random
import std/times
import image/simd

test "simd idct matches scalar exactly":
  var rng = initRand(2026)
  for _ in 0..<50:
    var coef: array[64, float64]
    var qt: array[64, int]
    for i in 0..63:
      coef[i] = float64(rng.rand(2047) - 1024)
      qt[i] = 1 + rng.rand(255)
    # sparse blocks like real JPEG data (mostly zeros after quant)
    if rng.rand(2) == 0:
      for i in 8..63:
        if rng.rand(4) != 0: coef[i] = 0.0
    check idctBlockSimd(coef, qt) == idctBlockScalar(coef, qt)

test "simd fdct matches scalar exactly":
  var rng = initRand(777)
  for _ in 0..<50:
    var px: array[64, float64]
    for i in 0..63: px[i] = float64(rng.rand(255)) - 128.0
    check fdctBlockSimd(px) == fdctBlockScalar(px)

test "simd dct round-trip vs scalar":
  var rng = initRand(31337)
  var px: array[64, float64]
  for i in 0..63: px[i] = float64(rng.rand(255)) - 128.0
  var qt: array[64, int]
  for i in 0..63: qt[i] = 8
  let fwd = fdctBlockSimd(px)
  var coef: array[64, float64]
  for i in 0..63: coef[i] = fwd[i] / 8.0
  let back = idctBlockSimd(coef, qt)
  let refBack = idctBlockSimd(coef, qt)
  check back == refBack

test "simd idct timing (informational)":
  var coef: array[64, float64]
  var qt: array[64, int]
  for i in 0..63:
    coef[i] = float64((i * 37) mod 1024) - 512.0
    qt[i] = 8 + (i mod 16)
  let t0 = cpuTime()
  for _ in 0..<2000:
    discard idctBlockScalar(coef, qt)
  let tScalar = cpuTime() - t0
  let t1 = cpuTime()
  for _ in 0..<2000:
    discard idctBlockSimd(coef, qt)
  let tSimd = cpuTime() - t1
  check idctBlockScalar(coef, qt) == idctBlockSimd(coef, qt)
  echo "IDCT x2000: scalar=" & $tScalar & "s simd=" & $tSimd & "s" &
    " (avx2=" & $useAvx2 & " neon=" & $useNeon & ")"
