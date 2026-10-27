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

test "simd ycbcr row matches scalar exactly":
  var rng = initRand(4242)
  for len in [0, 1, 2, 3, 5, 7, 8, 9, 15, 16, 17, 100, 1000, 4096]:
    var yA = newSeq[uint8](len); var cbA = newSeq[uint8](len)
    var crA = newSeq[uint8](len)
    for i in 0..<len:
      yA[i] = uint8(rng.rand(255))
      cbA[i] = uint8(rng.rand(255))
      crA[i] = uint8(rng.rand(255))
    var outA = newSeq[uint8](len * 3)
    var outB = newSeq[uint8](len * 3)
    if len > 0:
      ycbcrRowScalar(addr yA[0], addr cbA[0], addr crA[0], addr outA[0], len)
      ycbcrRowSimd(addr yA[0], addr cbA[0], addr crA[0], addr outB[0], len)
    check outA == outB

test "simd ycbcr row timing (informational)":
  const W = 3840
  var yR = newSeq[uint8](W); var cbR = newSeq[uint8](W); var crR = newSeq[uint8](W)
  for i in 0..<W:
    yR[i] = uint8(i and 0xFF); cbR[i] = uint8((i * 3) and 0xFF)
    crR[i] = uint8((i * 5) and 0xFF)
  var outS = newSeq[uint8](W * 3); var outV = newSeq[uint8](W * 3)
  let yt0 = cpuTime()
  for _ in 0..<200:
    ycbcrRowScalar(addr yR[0], addr cbR[0], addr crR[0], addr outS[0], W)
  let ytScalar = cpuTime() - yt0
  let yt1 = cpuTime()
  for _ in 0..<200:
    ycbcrRowSimd(addr yR[0], addr cbR[0], addr crR[0], addr outV[0], W)
  let ytSimd = cpuTime() - yt1
  check outS == outV
  echo "YCbCr 3840px row x200: scalar=" & $ytScalar & "s simd=" & $ytSimd & "s" &
    " (avx2=" & $useAvx2 & " neon=" & $useNeon & ")"
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
