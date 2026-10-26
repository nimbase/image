## PNG Up-filter kernel, SSE2 baseline (no extra compiler flags needed on x86_64).
when defined(amd64):
  import nimsimd/sse2

  proc upRowSse2*(curP, prevP: ptr uint8, n16: int) =
    ## Adds `prevP[0..<n16]` into `curP[0..<n16]`; `n16` must be a
    ## multiple of 16. Wrapping byte add matches the PNG spec.
    var i = 0
    while i < n16:
      let a = mm_loadu_si128(cast[pointer](cast[int](curP) + i))
      let b = mm_loadu_si128(cast[pointer](cast[int](prevP) + i))
      mm_storeu_si128(cast[pointer](cast[int](curP) + i), mm_add_epi8(a, b))
      i += 16

  template g(p: ptr float64, i: int): ptr float64 =
    cast[ptr float64](cast[int](p) + i * 8)

  proc idctPass1Sse2*(tmpP, midP, cosP, cfacP: ptr float64) =
    ## First IDCT pass: `mid[y][x] += (Cfac[u] * tmp[y][u]) * CosT[u][x]`.
    for y in 0..7:
      for u in 0..7:
        let kk = mm_set1_pd(g(cfacP, u)[] * g(tmpP, y*8+u)[])
        var i = 0
        while i < 8:
          let d = mm_loadu_pd(g(midP, y*8+i))
          let t = mm_loadu_pd(g(cosP, u*8+i))
          mm_storeu_pd(g(midP, y*8+i), mm_add_pd(d, mm_mul_pd(t, kk)))
          i += 2

  proc idctPass2Sse2*(midP, outP, cosP, cfacP: ptr float64) =
    ## Second IDCT pass: `out[y][x] += (Cfac[v] * mid[v][x]) * CosT[v][y]`.
    for y in 0..7:
      for v in 0..7:
        let cc = mm_set1_pd(g(cfacP, v)[])
        let tt = mm_set1_pd(g(cosP, v*8+y)[])
        var i = 0
        while i < 8:
          let d = mm_loadu_pd(g(outP, y*8+i))
          let m = mm_loadu_pd(g(midP, v*8+i))
          mm_storeu_pd(g(outP, y*8+i),
            mm_add_pd(d, mm_mul_pd(mm_mul_pd(cc, m), tt)))
          i += 2

  proc fdctPass1Sse2*(pxP, midP, cosP, cfacP: ptr float64) =
    ## First FDCT pass: `mid[v][x] += px[y][x] * CosT[v][y]`, then scale rows.
    for v in 0..7:
      for y in 0..7:
        let kk = mm_set1_pd(g(cosP, v*8+y)[])
        var i = 0
        while i < 8:
          let d = mm_loadu_pd(g(midP, v*8+i))
          let t = mm_loadu_pd(g(pxP, y*8+i))
          mm_storeu_pd(g(midP, v*8+i), mm_add_pd(d, mm_mul_pd(t, kk)))
          i += 2
      let cc = mm_set1_pd(g(cfacP, v)[])
      var j = 0
      while j < 8:
        let m = mm_loadu_pd(g(midP, v*8+j))
        mm_storeu_pd(g(midP, v*8+j), mm_mul_pd(m, cc))
        j += 2

  proc fdctPass2Sse2*(midP, resP, cosP, cfacP: ptr float64) =
    ## Second FDCT pass: dot products summed in scalar order, then scaled.
    var acc: array[8, float64]
    for v in 0..7:
      for u in 0..7:
        for i in 0..7: acc[i] = 0.0
        var i = 0
        while i < 8:
          let d = mm_loadu_pd(addr acc[i])
          let x = mm_loadu_pd(g(midP, v*8+i))
          let y = mm_loadu_pd(g(cosP, u*8+i))
          mm_storeu_pd(addr acc[i], mm_add_pd(d, mm_mul_pd(x, y)))
          i += 2
        var s = 0.0
        for x in 0..7: s += acc[x]
        g(resP, v*8+u)[] = s * g(cfacP, u)[]
