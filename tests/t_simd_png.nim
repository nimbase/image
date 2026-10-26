import unittest
import std/random
import std/times
import image/simd

test "simd up matches scalar across lengths":
  var rng = initRand(1234)
  for len in [0, 1, 7, 15, 16, 17, 31, 32, 33, 63, 64, 100, 1000, 4096]:
    var curA = newSeq[uint8](len); var curB = newSeq[uint8](len)
    var prev = newSeq[uint8](len)
    for i in 0..<len:
      curA[i] = uint8(rng.rand(255)); prev[i] = uint8(rng.rand(255))
    curB = curA
    check unfilterRowScalar(2, curA, prev, 4) == true
    check simdUnfilterRow(2, curB, prev, 4) == true
    check curA == curB

test "simd all filters match scalar":
  var rng = initRand(99)
  for filter in [0'u8, 1, 2, 3, 4]:
    for bpp in [1, 2, 3, 4, 6, 8]:
      for len in [0, 1, 5, 16, 17, 48, 300]:
        var curA = newSeq[uint8](len); var prev = newSeq[uint8](len)
        for i in 0..<len:
          curA[i] = uint8(rng.rand(255)); prev[i] = uint8(rng.rand(255))
        var curB = curA
        let a = unfilterRowScalar(filter, curA, prev, bpp)
        let b = simdUnfilterRow(filter, curB, prev, bpp)
        check a == b
        check curA == curB

test "simd rejects bad filter":
  var cur = @[1'u8, 2, 3]; var prev = @[4'u8, 5, 6]
  check simdUnfilterRow(9, cur, prev, 1) == false

test "simd up timing (informational)":
  # 4K RGBA row, 200 iterations. Prints scalar vs SIMD ms; asserts equality.
  const W = 4096 * 4
  var curS = newSeq[uint8](W); var curV = newSeq[uint8](W)
  var prev = newSeq[uint8](W)
  for i in 0..<W:
    curS[i] = uint8(i and 0xFF); prev[i] = uint8((i * 7) and 0xFF)
  curV = curS
  let t0 = cpuTime()
  for _ in 0..<200:
    var c = curS; discard unfilterRowScalar(2, c, prev, 4)
  let tScalar = cpuTime() - t0
  let t1 = cpuTime()
  for _ in 0..<200:
    var c = curV; discard simdUnfilterRow(2, c, prev, 4)
  let tSimd = cpuTime() - t1
  var a = curS; var b = curV
  discard unfilterRowScalar(2, a, prev, 4)
  discard simdUnfilterRow(2, b, prev, 4)
  check a == b
  echo "Up 16KB row x200: scalar=" & $tScalar & "s simd=" & $tSimd & "s" &
    " (avx2=" & $useAvx2 & " neon=" & $useNeon & ")"
