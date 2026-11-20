## PNG Up-filter kernel, ARM NEON (16 bytes per iteration).
## All Apple Silicon and modern ARM64 chips have NEON; still reached only
## through the runtime dispatcher in `image/simd` with a scalar fallback.
when defined(arm64):
  # ARM64 always has FMA: without this, scalar a*b+c fuses to one
  # rounding while the NEON intrinsics below stay separate (off-by-one
  # after int truncation). See image/simd.
  when defined(gcc) or defined(clang):
    {.localPassc: "-ffp-contract=off".}
  import nimsimd/neon

  {.push header: "arm_neon.h".}
  # Missing from nimsimd 1.3.2 (present on master): trivial f64 bindings.
  func vld1q_f64*(p: ptr float64): float64x2 {.importc: "vld1q_f64".}
  func vst1q_f64*(p: ptr float64, v: float64x2) {.importc: "vst1q_f64".}
  func vaddq_f64*(a, b: float64x2): float64x2 {.importc: "vaddq_f64".}
  func vsubq_f64*(a, b: float64x2): float64x2 {.importc: "vsubq_f64".}
  func vmulq_f64*(a, b: float64x2): float64x2 {.importc: "vmulq_f64".}
  {.pop.}

  proc ycbcrRowNeon*(yP, cbP, crP, rgbP: ptr uint8, n2: int) =
    ## YCbCr to interleaved RGB over `n2` pixels (`n2` even).
    ## Same op order/grouping as the scalar converter: bit-identical.
    ## Conversion to int stays scalar (nimsimd 1.3.2 lacks vcvt f64).
    let Y = cast[ptr UncheckedArray[uint8]](yP)
    let Cb = cast[ptr UncheckedArray[uint8]](cbP)
    let Cr = cast[ptr UncheckedArray[uint8]](crP)
    let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
    var cc = [128.0, 128.0]
    var k1 = [1.402, 1.402]
    var k2 = [0.344136, 0.344136]
    var k3 = [0.714136, 0.714136]
    var k4 = [1.772, 1.772]
    var hh = [0.5, 0.5]
    let c128 = vld1q_f64(addr cc[0])
    let k1402 = vld1q_f64(addr k1[0])
    let k0344 = vld1q_f64(addr k2[0])
    let k0714 = vld1q_f64(addr k3[0])
    let k1772 = vld1q_f64(addr k4[0])
    let half = vld1q_f64(addr hh[0])
    var o: array[2, float64]
    var i = 0
    while i < n2:
      var yy = [float64(Y[i]), float64(Y[i+1])]
      var cb = [float64(Cb[i]), float64(Cb[i+1])]
      var cr = [float64(Cr[i]), float64(Cr[i+1])]
      let yv = vld1q_f64(addr yy[0])
      let cbv = vsubq_f64(vld1q_f64(addr cb[0]), c128)
      let crv = vsubq_f64(vld1q_f64(addr cr[0]), c128)
      vst1q_f64(addr o[0],
        vaddq_f64(vaddq_f64(yv, vmulq_f64(k1402, crv)), half))
      Rgb[3*i] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+3] = uint8(clamp(int(o[1]), 0, 255))
      vst1q_f64(addr o[0], vaddq_f64(vsubq_f64(vsubq_f64(yv,
        vmulq_f64(k0344, cbv)), vmulq_f64(k0714, crv)), half))
      Rgb[3*i+1] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+4] = uint8(clamp(int(o[1]), 0, 255))
      vst1q_f64(addr o[0],
        vaddq_f64(vaddq_f64(yv, vmulq_f64(k1772, cbv)), half))
      Rgb[3*i+2] = uint8(clamp(int(o[0]), 0, 255))
      Rgb[3*i+5] = uint8(clamp(int(o[1]), 0, 255))
      i += 2

  proc ycbcrRowRgbaNeon*(yP, cbP, crP, rgbaP: ptr uint8, n2: int) =
    ## YCbCr to interleaved RGBA over `n2` pixels (`n2` even), alpha 255.
    ## Same op order/grouping as `ycbcrRowNeon`: bit-identical RGB lanes.
    ## Conversion to int stays scalar (nimsimd 1.3.2 lacks vcvt f64).
    let Y = cast[ptr UncheckedArray[uint8]](yP)
    let Cb = cast[ptr UncheckedArray[uint8]](cbP)
    let Cr = cast[ptr UncheckedArray[uint8]](crP)
    let Rgba = cast[ptr UncheckedArray[uint8]](rgbaP)
    var cc = [128.0, 128.0]
    var k1 = [1.402, 1.402]
    var k2 = [0.344136, 0.344136]
    var k3 = [0.714136, 0.714136]
    var k4 = [1.772, 1.772]
    var hh = [0.5, 0.5]
    let c128 = vld1q_f64(addr cc[0])
    let k1402 = vld1q_f64(addr k1[0])
    let k0344 = vld1q_f64(addr k2[0])
    let k0714 = vld1q_f64(addr k3[0])
    let k1772 = vld1q_f64(addr k4[0])
    let half = vld1q_f64(addr hh[0])
    var o: array[2, float64]
    var i = 0
    while i < n2:
      var yy = [float64(Y[i]), float64(Y[i+1])]
      var cb = [float64(Cb[i]), float64(Cb[i+1])]
      var cr = [float64(Cr[i]), float64(Cr[i+1])]
      let yv = vld1q_f64(addr yy[0])
      let cbv = vsubq_f64(vld1q_f64(addr cb[0]), c128)
      let crv = vsubq_f64(vld1q_f64(addr cr[0]), c128)
      vst1q_f64(addr o[0],
        vaddq_f64(vaddq_f64(yv, vmulq_f64(k1402, crv)), half))
      Rgba[4*i] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+4] = uint8(clamp(int(o[1]), 0, 255))
      vst1q_f64(addr o[0], vaddq_f64(vsubq_f64(vsubq_f64(yv,
        vmulq_f64(k0344, cbv)), vmulq_f64(k0714, crv)), half))
      Rgba[4*i+1] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+5] = uint8(clamp(int(o[1]), 0, 255))
      vst1q_f64(addr o[0],
        vaddq_f64(vaddq_f64(yv, vmulq_f64(k1772, cbv)), half))
      Rgba[4*i+2] = uint8(clamp(int(o[0]), 0, 255))
      Rgba[4*i+6] = uint8(clamp(int(o[1]), 0, 255))
      Rgba[4*i+3] = 255'u8
      Rgba[4*i+7] = 255'u8
      i += 2

  template f64p(p: ptr float64, i: int): ptr float64 =
    cast[ptr float64](cast[int](p) + i * 8)

  proc upRowNeon*(curP, prevP: ptr uint8, n16: int) =
    ## Adds `prevP[0..<n16]` into `curP[0..<n16]`; `n16` must be a
    ## multiple of 16.
    var i = 0
    while i < n16:
      let a = vld1q_u8(cast[pointer](cast[int](curP) + i))
      let b = vld1q_u8(cast[pointer](cast[int](prevP) + i))
      vst1q_u8(cast[pointer](cast[int](curP) + i), vaddq_u8(a, b))
      i += 16

  # --- PNG chained-filter kernels (Sub / Average / Paeth) ---
  #
  # Mirror of the SSE2 kernels above: same chunking, same seed-from-
  # buffer discipline, same frontier masks, bit-identical results.
  # Differences are mechanical: left-shifts go through `vqtbl1q_u8`
  # with a per-shift index table (out-of-range lanes yield zero),
  # Average folds via widen-add + truncating narrow (exact floor),
  # and `vminq_u8`/`vqaddq_u8` (absent in nimsimd 1.3.2) are emulated
  # with max+select and wrap-detect blends.

  template shiftIdxNeon(s: int, dst: var array[16, uint8]) =
    ## Index table for a left byte-shift by `s`: lane `i` takes
    ## `v[i-s]`, low lanes take 255 (out of range -> zero in `vqtbl`).
    for qi in 0..<16:
      dst[qi] = if qi >= s: uint8(qi - s) else: 255'u8

  template shlNeon(v, idx: uint8x16): uint8x16 =
    vqtbl1q_u8(v, idx)

  template ultNeon(x, y: uint8x16): uint8x16 =
    ## Unsigned byte `<` mask: x<y iff max(x,y)==y and x!=y.
    vbicq_u8(vceqq_u8(vmaxq_u8(x, y), y), vceqq_u8(x, y))

  template minNeon(a, b: uint8x16): uint8x16 =
    ## `vminq_u8` emulation: pick `b` where `max == a`.
    vbslq_u8(vceqq_u8(vmaxq_u8(a, b), a), b, a)

  proc subRowNeon*(curP: ptr uint8, n: int, bpp: int) =
    ## In-place Sub reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {1,2,3,4,6,8}; tail (< 16 bytes) runs scalar.
    let c = cast[ptr UncheckedArray[uint8]](curP)
    var carry: array[8, uint8]
    var t1, t2, t3, t4, t6, t8, t12: array[16, uint8]
    shiftIdxNeon(1, t1); shiftIdxNeon(2, t2); shiftIdxNeon(3, t3)
    shiftIdxNeon(4, t4); shiftIdxNeon(6, t6); shiftIdxNeon(8, t8)
    shiftIdxNeon(12, t12)
    let sh1 = vld1q_u8(cast[pointer](addr t1[0]))
    let sh2 = vld1q_u8(cast[pointer](addr t2[0]))
    let sh3 = vld1q_u8(cast[pointer](addr t3[0]))
    let sh4 = vld1q_u8(cast[pointer](addr t4[0]))
    let sh6 = vld1q_u8(cast[pointer](addr t6[0]))
    let sh8 = vld1q_u8(cast[pointer](addr t8[0]))
    let sh12 = vld1q_u8(cast[pointer](addr t12[0]))
    let m = (n div 16) * 16
    template chunk(bppC: static int) =
      var i = 0
      while i < m:
        for j in 0..<bppC:
          c[i+j] = uint8((int(c[i+j]) + int(carry[j])) and 0xFF)
        var v = vld1q_u8(cast[pointer](cast[int](curP) + i))
        when bppC == 1:
          v = vaddq_u8(v, shlNeon(v, sh1))
          v = vaddq_u8(v, shlNeon(v, sh2))
          v = vaddq_u8(v, shlNeon(v, sh4))
          v = vaddq_u8(v, shlNeon(v, sh8))
        elif bppC == 2:
          v = vaddq_u8(v, shlNeon(v, sh2))
          v = vaddq_u8(v, shlNeon(v, sh4))
          v = vaddq_u8(v, shlNeon(v, sh8))
        elif bppC == 3:
          v = vaddq_u8(v, shlNeon(v, sh3))
          v = vaddq_u8(v, shlNeon(v, sh6))
          v = vaddq_u8(v, shlNeon(v, sh12))
        elif bppC == 4:
          v = vaddq_u8(v, shlNeon(v, sh4))
          v = vaddq_u8(v, shlNeon(v, sh8))
        elif bppC == 6:
          v = vaddq_u8(v, shlNeon(v, sh6))
          v = vaddq_u8(v, shlNeon(v, sh12))
        else:
          v = vaddq_u8(v, shlNeon(v, sh8))
        vst1q_u8(cast[pointer](cast[int](curP) + i), v)
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

  template avgEstNeon(t, p: uint8x16): uint8x16 =
    ## floor((t+p)/2), bit-identical to scalar `(a+b) div 2`:
    ## widen, add, truncating shift-narrow per half.
    let lo = vaddl_u8(vget_low_u8(t), vget_low_u8(p))
    let hi = vaddl_u8(vget_high_u8(t), vget_high_u8(p))
    vcombine_u8(vshrn_n_u16(lo, 1), vshrn_n_u16(hi, 1))

  proc avgRowNeon*(curP, prevP: ptr uint8, n: int, bpp: int) =
    ## In-place Average reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {3,4,6,8}; 16-byte chunks (5/3/2/1 frontiers).
    let c = cast[ptr UncheckedArray[uint8]](curP)
    let pr = cast[ptr UncheckedArray[uint8]](prevP)
    var carry: array[8, uint8]
    var ts: array[16, uint8]
    template chunk(bppC: static int, Rounds: static int) =
      shiftIdxNeon(bppC, ts)
      let sh = vld1q_u8(cast[pointer](addr ts[0]))
      var masks: array[5, array[16, uint8]]
      for r in 1..Rounds:
        for q in 0..<16:
          masks[r-1][q] =
            if q >= r*bppC and q < min((r+1)*bppC, 16): 255'u8 else: 0'u8
      var i = 0
      while i + 16 <= n:
        for j in 0..<bppC:
          c[i+j] = uint8((int(c[i+j]) +
            ((int(carry[j]) + int(pr[i+j])) div 2)) and 0xFF)
        let prevV = vld1q_u8(cast[pointer](cast[int](prevP) + i))
        var v = vld1q_u8(cast[pointer](cast[int](curP) + i))
        let rawV = v
        for r in 1..Rounds:
          let fmask = vld1q_u8(cast[pointer](addr masks[r-1][0]))
          let t = shlNeon(v, sh)
          let e = vaddq_u8(rawV, avgEstNeon(t, prevV))
          v = vorrq_u8(vbicq_u8(v, fmask), vandq_u8(fmask, e))
        vst1q_u8(cast[pointer](cast[int](curP) + i), v)
        for j in 0..<bppC:
          carry[j] = c[i+16-bppC+j]
        i += 16
      while i < n:
        c[i] = uint8((int(c[i]) +
          ((int(c[i-bpp]) + int(pr[i])) div 2)) and 0xFF)
        inc i
    case bpp
    of 3: chunk(3, 5)
    of 4: chunk(4, 3)
    of 6: chunk(6, 2)
    else: chunk(8, 1)

  template paethEstNeon(a, b, cc: uint8x16): uint8x16 =
    ## Paeth predictor, bit-identical to the scalar `paeth` (strict
    ## `<` chains prefer a, then b). Stays in u8: absolute differences
    ## use max-min (exact), pc saturates at 255 via wrap-detect
    ## (`sum|ov`: overflow lanes are already 0xFF-masked by `ov`;
    ## decision-preserving since pa/pb <= 255 always). Sign equality
    ## compares unnegated masks (equality is negation-invariant).
    let pa = vsubq_u8(vmaxq_u8(b, cc), minNeon(b, cc))
    let pb = vsubq_u8(vmaxq_u8(a, cc), minNeon(a, cc))
    let same = vceqq_u8(vceqq_u8(vmaxq_u8(a, cc), a),
      vceqq_u8(vmaxq_u8(b, cc), b))
    let sumw = vaddq_u8(pa, pb)
    let sum = vorrq_u8(sumw, ultNeon(sumw, pa))
    let dif = vsubq_u8(vmaxq_u8(pa, pb), minNeon(pa, pb))
    let pc = vbslq_u8(same, sum, dif)
    let m1 = ultNeon(pb, pa)
    let r1 = vbslq_u8(m1, b, a)
    let pr1 = vbslq_u8(m1, pb, pa)
    let m2 = ultNeon(pc, pr1)
    vbslq_u8(m2, cc, r1)

  proc paethRowNeon*(curP, prevP: ptr uint8, n: int, bpp: int) =
    ## In-place Paeth reconstruction over `n` bytes (`n >= 16).
    ## `bpp` in {4,6,8}; bpp-4 uses 8-byte chunks (one frontier),
    ## 6/8 use 16-byte chunks (two/one frontiers).
    let c = cast[ptr UncheckedArray[uint8]](curP)
    let pr = cast[ptr UncheckedArray[uint8]](prevP)
    var carry: array[8, uint8]
    var pcarry: array[8, uint8]
    var ts: array[16, uint8]
    var z8: array[8, uint8]
    let zero8 = vld1_u8(cast[pointer](addr z8[0]))
    template chunk(bppC: static int, W: static int, Rounds: static int) =
      shiftIdxNeon(bppC, ts)
      let sh = vld1q_u8(cast[pointer](addr ts[0]))
      var masks: array[5, array[16, uint8]]
      for r in 1..Rounds:
        for q in 0..<16:
          masks[r-1][q] =
            if q >= r*bppC and q < min((r+1)*bppC, W): 255'u8 else: 0'u8
      template loadQ(p: ptr uint8): uint8x16 =
        when W == 8:
          vcombine_u8(vld1_u8(cast[pointer](p)), zero8)
        else:
          vld1q_u8(cast[pointer](p))
      template storeQ(p: ptr uint8, v: uint8x16) =
        when W == 8:
          vst1_u8(cast[pointer](p), vget_low_u8(v))
        else:
          vst1q_u8(cast[pointer](p), v)
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
        let prevV = loadQ(cast[ptr uint8](cast[int](prevP) + i))
        let prevcV =
          if i == 0: shlNeon(prevV, sh)
          else: loadQ(cast[ptr uint8](cast[int](prevP) + i - bppC))
        var v = loadQ(cast[ptr uint8](cast[int](curP) + i))
        let rawV = v
        for r in 1..Rounds:
          let fmask = vld1q_u8(cast[pointer](addr masks[r-1][0]))
          let t = shlNeon(v, sh)
          let e = vaddq_u8(rawV, paethEstNeon(t, prevV, prevcV))
          v = vorrq_u8(vbicq_u8(v, fmask), vandq_u8(fmask, e))
        storeQ(cast[ptr uint8](cast[int](curP) + i), v)
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

  proc fdctPass1Neon*(pxP, midP, cosP, cfacP: ptr float64) =
    ## First FDCT pass: `mid[v][x] += px[y][x] * CosT[v][y]`, then scale rows.
    for v in 0..7:
      for y in 0..7:
        var kk = [f64p(cosP, v*8+y)[], 0.0]
        kk[1] = kk[0]
        let kv = vld1q_f64(addr kk[0])
        var i = 0
        while i < 8:
          let d = vld1q_f64(f64p(midP, v*8+i))
          let t = vld1q_f64(f64p(pxP, y*8+i))
          vst1q_f64(f64p(midP, v*8+i), vaddq_f64(d, vmulq_f64(t, kv)))
          i += 2
      var cc = [f64p(cfacP, v)[], 0.0]
      cc[1] = cc[0]
      let cv = vld1q_f64(addr cc[0])
      var j = 0
      while j < 8:
        let m = vld1q_f64(f64p(midP, v*8+j))
        vst1q_f64(f64p(midP, v*8+j), vmulq_f64(m, cv))
        j += 2

  proc fdctPass2Neon*(midP, resP, cosP, cfacP: ptr float64) =
    ## Second FDCT pass: dot products summed in scalar order, then scaled.
    var acc: array[8, float64]
    for v in 0..7:
      for u in 0..7:
        for i in 0..7: acc[i] = 0.0
        var i = 0
        while i < 8:
          let d = vld1q_f64(addr acc[i])
          let x = vld1q_f64(f64p(midP, v*8+i))
          let y = vld1q_f64(f64p(cosP, u*8+i))
          vst1q_f64(addr acc[i], vaddq_f64(d, vmulq_f64(x, y)))
          i += 2
        var s = 0.0
        for x in 0..7: s += acc[x]
        f64p(resP, v*8+u)[] = s * f64p(cfacP, u)[]
