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
      for len in [0, 1, 5, 16, 17, 31, 32, 33, 47, 48, 49, 100, 300]:
        var curA = newSeq[uint8](len); var prev = newSeq[uint8](len)
        for i in 0..<len:
          curA[i] = uint8(rng.rand(255)); prev[i] = uint8(rng.rand(255))
        var curB = curA
        let a = unfilterRowScalar(filter, curA, prev, bpp)
        let b = simdUnfilterRow(filter, curB, prev, bpp)
        check a == b
        check curA == curB

test "simd chained filters match scalar on photo-width rows":
  # 2048px rows at photo bpp: chunking, carries and tails exercised
  # over many chunks (the unit test above covers edges).
  var rng = initRand(2026)
  for (filter, bpp, rowB) in [(1'u8, 4, 8192), (1'u8, 3, 6144),
      (1'u8, 1, 2048), (1'u8, 8, 16384), (3'u8, 4, 8192),
      (3'u8, 3, 6144), (3'u8, 8, 16384), (4'u8, 4, 8192),
      (4'u8, 6, 12288), (4'u8, 8, 16384)]:
    var curA = newSeq[uint8](rowB); var prev = newSeq[uint8](rowB)
    for i in 0..<rowB:
      curA[i] = uint8(rng.rand(255)); prev[i] = uint8(rng.rand(255))
    var curB = curA
    check unfilterRowScalar(filter, curA, prev, bpp) == true
    check simdUnfilterRow(filter, curB, prev, bpp) == true
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

test "simd chained filters timing (informational)":
  # Per-filter scalar vs SIMD on photo-width rows. Asserts equality;
  # prints the speedup so bpp thresholds stay evidence-based.
  var rng = initRand(7)
  for (filter, bpp, rowB) in [(1'u8, 4, 8192), (1'u8, 1, 2048),
      (3'u8, 4, 8192), (3'u8, 3, 6144), (3'u8, 6, 12288),
      (3'u8, 8, 16384), (3'u8, 1, 2048),
      (4'u8, 4, 8192), (4'u8, 6, 12288), (4'u8, 3, 6144)]:
    var curS = newSeq[uint8](rowB); var prev = newSeq[uint8](rowB)
    for i in 0..<rowB:
      curS[i] = uint8(rng.rand(255)); prev[i] = uint8(rng.rand(255))
    var curV = curS
    let t0 = cpuTime()
    for _ in 0..<200:
      var c = curS; discard unfilterRowScalar(filter, c, prev, bpp)
    let tScalar = cpuTime() - t0
    let t1 = cpuTime()
    for _ in 0..<200:
      var c = curV; discard simdUnfilterRow(filter, c, prev, bpp)
    let tSimd = cpuTime() - t1
    var a = curS; var b = curV
    discard unfilterRowScalar(filter, a, prev, bpp)
    discard simdUnfilterRow(filter, b, prev, bpp)
    check a == b
    echo "filter=" & $filter & " bpp=" & $bpp & " rowB=" & $rowB &
      ": scalar=" & $tScalar & "s simd=" & $tSimd & "s"
