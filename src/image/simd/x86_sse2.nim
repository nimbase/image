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

  # --- PNG chained-filter kernels (Sub / Average / Paeth) ---
  #
  # Unlike Up (embarrassingly parallel), these chain on `cur[i-bpp]`:
  # each chunk seeds its first `bpp` bytes from the already-final
  # buffer bytes just before it (zeros for chunk 0, matching the
  # scalar a=0/c=0 rule), then propagates within the chunk.
  #
  # Sub is linear (mod-256 addition commutes), so doubling shifts
  # compose: shifts bpp, 2*bpp, ... cover the chunk exactly like the
  # scalar prefix sum, byte-identical. Average/Paeth estimators are
  # nonlinear, so each round advances exactly one frontier
  # ([r*bpp, (r+1)*bpp), blended via a mask) over the raw bytes: every
  # byte sees one estimator application on final taps, same inputs and
  # truncation as the scalar loop. Width stays 16 (SSE2): chained
  # filters are dependency-bound, so wider vectors add rounds without
  # adding parallelism (unlike Up, which has a 32-byte AVX2 path).
  # bpp 1/2 Average/Paeth and bpp-3 Paeth stay scalar: 5+ frontier
  # rounds cost more than the scalar loop (measured, see t_simd_png).

  template subDoubling(bpp: static int, v: var M128i) =
    ## One doubling-shift round sequence for Sub over a 16-byte chunk.
    ## After the rounds each byte holds raw[i] + raw[i-bpp] + ...,
    ## the same mod-256 sum the scalar loop accumulates.
    when bpp == 1:
      v = mm_add_epi8(v, mm_bslli_si128(v, 1))
      v = mm_add_epi8(v, mm_bslli_si128(v, 2))
      v = mm_add_epi8(v, mm_bslli_si128(v, 4))
      v = mm_add_epi8(v, mm_bslli_si128(v, 8))
    elif bpp == 2:
      v = mm_add_epi8(v, mm_bslli_si128(v, 2))
      v = mm_add_epi8(v, mm_bslli_si128(v, 4))
      v = mm_add_epi8(v, mm_bslli_si128(v, 8))
    elif bpp == 3:
      v = mm_add_epi8(v, mm_bslli_si128(v, 3))
      v = mm_add_epi8(v, mm_bslli_si128(v, 6))
      v = mm_add_epi8(v, mm_bslli_si128(v, 12))
    elif bpp == 4:
      v = mm_add_epi8(v, mm_bslli_si128(v, 4))
      v = mm_add_epi8(v, mm_bslli_si128(v, 8))
    elif bpp == 6:
      v = mm_add_epi8(v, mm_bslli_si128(v, 6))
      v = mm_add_epi8(v, mm_bslli_si128(v, 12))
    elif bpp == 8:
      v = mm_add_epi8(v, mm_bslli_si128(v, 8))

  proc subRowSse2*(curP: ptr uint8, n: int, bpp: int) =
    ## In-place Sub reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {1,2,3,4,6,8}; tail (< 16 bytes) runs scalar.
    let c = cast[ptr UncheckedArray[uint8]](curP)
    var carry: array[8, uint8]
    let m = (n div 16) * 16
    template chunk(bppC: static int) =
      var i = 0
      while i < m:
        for j in 0..<bppC:
          c[i+j] = uint8((int(c[i+j]) + int(carry[j])) and 0xFF)
        var v = mm_loadu_si128(cast[pointer](cast[int](curP) + i))
        subDoubling(bppC, v)
        mm_storeu_si128(cast[pointer](cast[int](curP) + i), v)
        for j in 0..<bppC:
          carry[j] = c[i+16-bppC+j]
        i += 16
    case bpp
    of 1: chunk(1)
    of 2: chunk(2)
    of 3: chunk(3)
    of 4: chunk(4)
    of 6: chunk(6)
    else: chunk(8)
    var k = m
    while k < n:
      c[k] = uint8((int(c[k]) + int(c[k-bpp])) and 0xFF)
      inc k

  template avgEstSse2(t, p, one: M128i): M128i =
    ## floor((t+p)/2), bit-identical to scalar `(a+b) div 2`:
    ## `pavgb` rounds up, so subtract 1 where parities differ.
    mm_sub_epi8(mm_avg_epu8(t, p),
      mm_and_si128(mm_xor_si128(t, p), one))

  proc avgRowSse2*(curP, prevP: ptr uint8, n: int, bpp: int) =
    ## In-place Average reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {3,4,6,8} (1/2 stay scalar: 7+ frontier rounds lose
    ## to the scalar loop). All bpp use 16-byte chunks (5/3/2/1
    ## frontiers); 8-byte chunks cost more in load bandwidth than
    ## the cheap estimator saves (measured).
    let c = cast[ptr UncheckedArray[uint8]](curP)
    let pr = cast[ptr UncheckedArray[uint8]](prevP)
    var carry: array[8, uint8]
    let one = mm_set1_epi8(1)
    template chunk(bppC: static int, W: static int, Rounds: static int) =
      var masks: array[5, array[16, uint8]]
      for r in 1..Rounds:
        for q in 0..<16:
          masks[r-1][q] =
            if q >= r*bppC and q < min((r+1)*bppC, W): 255'u8 else: 0'u8
      var i = 0
      while i + W <= n:
        for j in 0..<bppC:
          c[i+j] = uint8((int(c[i+j]) +
            ((int(carry[j]) + int(pr[i+j])) div 2)) and 0xFF)
        let prevV = mm_loadu_si128(cast[pointer](cast[int](prevP) + i))
        var v = mm_loadu_si128(cast[pointer](cast[int](curP) + i))
        let rawV = v
        for r in 1..Rounds:
          let fmask = mm_loadu_si128(addr masks[r-1][0])
          let t = mm_bslli_si128(v, bppC)
          let e = mm_add_epi8(rawV, avgEstSse2(t, prevV, one))
          v = mm_or_si128(mm_andnot_si128(fmask, v),
            mm_and_si128(fmask, e))
        when W == 8:
          mm_storel_epi64(cast[pointer](cast[int](curP) + i), v)
        else:
          mm_storeu_si128(cast[pointer](cast[int](curP) + i), v)
        for j in 0..<bppC:
          carry[j] = c[i+W-bppC+j]
        i += W
      # scalar tail (taps already final in the buffer)
      while i < n:
        c[i] = uint8((int(c[i]) +
          ((int(c[i-bpp]) + int(pr[i])) div 2)) and 0xFF)
        inc i
    case bpp
    of 3: chunk(3, 16, 5)
    of 4: chunk(4, 16, 3)
    of 6: chunk(6, 16, 2)
    else: chunk(8, 16, 1)

  template ultSse2(x, y: M128i): M128i =
    ## Unsigned byte `<` mask (SSE2 has only signed compares):
    ## x<y iff max(x,y)==y and x!=y.
    mm_andnot_si128(mm_cmpeq_epi8(x, y),
      mm_cmpeq_epi8(mm_max_epu8(x, y), y))

  template paethEstSse2(a, b, cc: M128i): M128i =
    ## Paeth predictor over full vectors, bit-identical to scalar
    ## `paeth` (same tie-breaking: strict `<` chains prefer a, then b).
    ## Stays in u8: pa/pb fit, and pc saturates at 255 without
    ## changing any comparison (pa/pb <= 255 always). Absolute
    ## differences use max-min (exact: max >= min never wraps); sign
    ## equality compares unnegated masks (negation-invariant).
    let pa = mm_sub_epi8(mm_max_epu8(b, cc), mm_min_epu8(b, cc))
    let pb = mm_sub_epi8(mm_max_epu8(a, cc), mm_min_epu8(a, cc))
    let same = mm_cmpeq_epi8(mm_cmpeq_epi8(mm_max_epu8(a, cc), a),
      mm_cmpeq_epi8(mm_max_epu8(b, cc), b))
    let sum = mm_adds_epu8(pa, pb)
    let dif = mm_sub_epi8(mm_max_epu8(pa, pb), mm_min_epu8(pa, pb))
    let pc = mm_or_si128(mm_and_si128(same, sum),
      mm_andnot_si128(same, dif))
    let m1 = ultSse2(pb, pa)
    let r1 = mm_or_si128(mm_andnot_si128(m1, a), mm_and_si128(m1, b))
    let pr1 = mm_or_si128(mm_andnot_si128(m1, pa), mm_and_si128(m1, pb))
    let m2 = ultSse2(pc, pr1)
    mm_or_si128(mm_andnot_si128(m2, r1), mm_and_si128(m2, cc))

  proc paethRowSse2*(curP, prevP: ptr uint8, n: int, bpp: int) =
    ## In-place Paeth reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {4,6,8} (1/2 need 7+ rounds and bpp-3 needs 5:
    ## measured slower than scalar, so they stay scalar).
    let c = cast[ptr UncheckedArray[uint8]](curP)
    let pr = cast[ptr UncheckedArray[uint8]](prevP)
    var carry: array[8, uint8]
    var pcarry: array[8, uint8]
    template chunk(bppC: static int, W: static int, Rounds: static int) =
      var masks: array[5, array[16, uint8]]
      for r in 1..Rounds:
        for q in 0..<16:
          masks[r-1][q] =
            if q >= r*bppC and q < min((r+1)*bppC, W): 255'u8 else: 0'u8
      var i = 0
      while i + W <= n:
        for j in 0..<bppC:
          let cc0 = if i == 0: 0 else: int(pcarry[j])
          let a0 = if i == 0: 0 else: int(carry[j])
          let b0 = int(pr[i+j])
          let pp = a0 + b0 - cc0
          let pa = abs(pp - a0); let pb = abs(pp - b0)
          let pc = abs(pp - cc0)
          let pred = if pa <= pb and pa <= pc: a0
            elif pb <= pc: b0 else: cc0
          c[i+j] = uint8((int(c[i+j]) + pred) and 0xFF)
        let prevV =
          when W == 8:
            mm_loadl_epi64(cast[pointer](cast[int](prevP) + i))
          else:
            mm_loadu_si128(cast[pointer](cast[int](prevP) + i))
        let prevcV =
          if i == 0: mm_bslli_si128(prevV, bppC)
          else:
            when W == 8:
              mm_loadl_epi64(cast[pointer](cast[int](prevP) + i - bppC))
            else:
              mm_loadu_si128(cast[pointer](cast[int](prevP) + i - bppC))
        var v =
          when W == 8:
            mm_loadl_epi64(cast[pointer](cast[int](curP) + i))
          else:
            mm_loadu_si128(cast[pointer](cast[int](curP) + i))
        let rawV = v
        for r in 1..Rounds:
          let fmask = mm_loadu_si128(addr masks[r-1][0])
          let t = mm_bslli_si128(v, bppC)
          let e = mm_add_epi8(rawV, paethEstSse2(t, prevV, prevcV))
          v = mm_or_si128(mm_andnot_si128(fmask, v),
            mm_and_si128(fmask, e))
        when W == 8:
          mm_storel_epi64(cast[pointer](cast[int](curP) + i), v)
        else:
          mm_storeu_si128(cast[pointer](cast[int](curP) + i), v)
        for j in 0..<bppC:
          carry[j] = c[i+W-bppC+j]
          pcarry[j] = pr[i+W-bppC+j]
        i += W
      while i < n:
        let a0 = int(c[i-bpp]); let b0 = int(pr[i])
        let cc0 = int(pr[i-bpp])
        let pp = a0 + b0 - cc0
        let pa = abs(pp - a0); let pb = abs(pp - b0)
        let pc = abs(pp - cc0)
        let pred = if pa <= pb and pa <= pc: a0
          elif pb <= pc: b0 else: cc0
        c[i] = uint8((int(c[i]) + pred) and 0xFF)
        inc i
    case bpp
    of 4: chunk(4, 8, 1)
    of 6: chunk(6, 16, 2)
    else: chunk(8, 16, 1)

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

  proc ycbcrRowRgbaSse2*(yP, cbP, crP, rgbaP: ptr uint8, n2: int) =
    ## YCbCr to interleaved RGBA over `n2` pixels (`n2` even), alpha 255.
    ## Same op order/grouping as `ycbcrRowSse2`: bit-identical RGB lanes.
    let Y = cast[ptr UncheckedArray[uint8]](yP)
    let Cb = cast[ptr UncheckedArray[uint8]](cbP)
    let Cr = cast[ptr UncheckedArray[uint8]](crP)
    let Rgba = cast[ptr UncheckedArray[uint8]](rgbaP)
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
      Rgba[4*i] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+4] = uint8(clamp(int(o[1]), 0, 255))
      mm_storel_epi64(addr o[0], mm_cvttpd_epi32(gv))
      Rgba[4*i+1] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+5] = uint8(clamp(int(o[1]), 0, 255))
      mm_storel_epi64(addr o[0], mm_cvttpd_epi32(bv))
      Rgba[4*i+2] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+6] = uint8(clamp(int(o[1]), 0, 255))
      Rgba[4*i+3] = 255'u8
      Rgba[4*i+7] = 255'u8
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
