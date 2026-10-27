## PNG Up-filter kernel, SSE2 baseline (no extra compiler flags needed on x86_64).
when defined(amd64):
  # Keep scalar oracle rounding identical to the vector kernels below:
  # with FMA available (always on arm64) the compiler would otherwise
  # fuse scalar a*b+c into one rounding while intrinsics stay separate.
  when defined(gcc) or defined(clang):
    {.localPassc: "-ffp-contract=off".}
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

  proc ycbcrRowSse2*(yP, cbP, crP, rgbP: ptr uint8, n2: int) =
    ## YCbCr to interleaved RGB over `n2` pixels (`n2` even).
    ## Same op order/grouping as the scalar converter: bit-identical.
    let Y = cast[ptr UncheckedArray[uint8]](yP)
    let Cb = cast[ptr UncheckedArray[uint8]](cbP)
    let Cr = cast[ptr UncheckedArray[uint8]](crP)
    let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
    let c128 = mm_set1_pd(128.0)
    let k1402 = mm_set1_pd(1.402)
    let k0344 = mm_set1_pd(0.344136)
    let k0714 = mm_set1_pd(0.714136)
    let k1772 = mm_set1_pd(1.772)
    let half = mm_set1_pd(0.5)
    var o: array[2, int32]
    var i = 0
    while i < n2:
      let yv = mm_set_pd(float64(Y[i+1]), float64(Y[i]))
      let cbv = mm_sub_pd(mm_set_pd(float64(Cb[i+1]), float64(Cb[i])), c128)
      let crv = mm_sub_pd(mm_set_pd(float64(Cr[i+1]), float64(Cr[i])), c128)
      let rv = mm_add_pd(mm_add_pd(yv, mm_mul_pd(k1402, crv)), half)
      let gv = mm_add_pd(mm_sub_pd(mm_sub_pd(yv, mm_mul_pd(k0344, cbv)),
        mm_mul_pd(k0714, crv)), half)
      let bv = mm_add_pd(mm_add_pd(yv, mm_mul_pd(k1772, cbv)), half)
      mm_storel_epi64(addr o[0], mm_cvttpd_epi32(rv))
      Rgb[3*i] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+3] = uint8(clamp(int(o[1]), 0, 255))
      mm_storel_epi64(addr o[0], mm_cvttpd_epi32(gv))
      Rgb[3*i+1] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+4] = uint8(clamp(int(o[1]), 0, 255))
      mm_storel_epi64(addr o[0], mm_cvttpd_epi32(bv))
      Rgb[3*i+2] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+5] = uint8(clamp(int(o[1]), 0, 255))
      i += 2

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
