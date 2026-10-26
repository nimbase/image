## PNG Up-filter kernel, AVX2 (32 bytes per iteration).
## Kept in its own file so the `-mavx2` flag never leaks into scalar code
## (auto-vectorized scalar tails must stay runnable on non-AVX2 CPUs).
when defined(amd64):
  when defined(gcc) or defined(clang):
    {.localPassc: "-mavx2".}

  import nimsimd/avx2

  proc upRowAvx2*(curP, prevP: ptr uint8, n32: int) =
    ## Adds `prevP[0..<n32]` into `curP[0..<n32]`; `n32` must be a
    ## multiple of 32.
    var i = 0
    while i < n32:
      let a = mm256_loadu_si256(cast[pointer](cast[int](curP) + i))
      let b = mm256_loadu_si256(cast[pointer](cast[int](prevP) + i))
      mm256_storeu_si256(cast[pointer](cast[int](curP) + i), mm256_add_epi8(a, b))
      i += 32

  template g(p: ptr float64, i: int): ptr float64 =
    cast[ptr float64](cast[int](p) + i * 8)

  proc idctPass1Avx*(tmpP, midP, cosP, cfacP: ptr float64) =
    ## First IDCT pass: `mid[y][x] += (Cfac[u] * tmp[y][u]) * CosT[u][x]`.
    for y in 0..7:
      for u in 0..7:
        let kk = mm256_set1_pd(g(cfacP, u)[] * g(tmpP, y*8+u)[])
        var i = 0
        while i < 8:
          let d = mm256_loadu_pd(g(midP, y*8+i))
          let t = mm256_loadu_pd(g(cosP, u*8+i))
          mm256_storeu_pd(g(midP, y*8+i), mm256_add_pd(d, mm256_mul_pd(t, kk)))
          i += 4

  proc idctPass2Avx*(midP, outP, cosP, cfacP: ptr float64) =
    ## Second IDCT pass: `out[y][x] += (Cfac[v] * mid[v][x]) * CosT[v][y]`.
    for y in 0..7:
      for v in 0..7:
        let cc = mm256_set1_pd(g(cfacP, v)[])
        let tt = mm256_set1_pd(g(cosP, v*8+y)[])
        var i = 0
        while i < 8:
          let d = mm256_loadu_pd(g(outP, y*8+i))
          let m = mm256_loadu_pd(g(midP, v*8+i))
          mm256_storeu_pd(g(outP, y*8+i),
            mm256_add_pd(d, mm256_mul_pd(mm256_mul_pd(cc, m), tt)))
          i += 4

  proc fdctPass1Avx*(pxP, midP, cosP, cfacP: ptr float64) =
    ## First FDCT pass: `mid[v][x] += px[y][x] * CosT[v][y]`, then scale rows.
    for v in 0..7:
      for y in 0..7:
        let kk = mm256_set1_pd(g(cosP, v*8+y)[])
        var i = 0
        while i < 8:
          let d = mm256_loadu_pd(g(midP, v*8+i))
          let t = mm256_loadu_pd(g(pxP, y*8+i))
          mm256_storeu_pd(g(midP, v*8+i), mm256_add_pd(d, mm256_mul_pd(t, kk)))
          i += 4
      let cc = mm256_set1_pd(g(cfacP, v)[])
      var j = 0
      while j < 8:
        let m = mm256_loadu_pd(g(midP, v*8+j))
        mm256_storeu_pd(g(midP, v*8+j), mm256_mul_pd(m, cc))
        j += 4

  proc fdctPass2Avx*(midP, resP, cosP, cfacP: ptr float64) =
    ## Second FDCT pass: dot products summed in scalar order, then scaled.
    var acc: array[8, float64]
    for v in 0..7:
      for u in 0..7:
        for i in 0..7: acc[i] = 0.0
        var i = 0
        while i < 8:
          let d = mm256_loadu_pd(addr acc[i])
          let x = mm256_loadu_pd(g(midP, v*8+i))
          let y = mm256_loadu_pd(g(cosP, u*8+i))
          mm256_storeu_pd(addr acc[i], mm256_add_pd(d, mm256_mul_pd(x, y)))
          i += 4
        var s = 0.0
        for x in 0..7: s += acc[x]
        g(resP, v*8+u)[] = s * g(cfacP, u)[]
