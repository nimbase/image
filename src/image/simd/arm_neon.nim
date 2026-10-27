## PNG Up-filter kernel, ARM NEON (16 bytes per iteration).
## All Apple Silicon and modern ARM64 chips have NEON; still reached only
## through the runtime dispatcher in `image/simd` with a scalar fallback.
when defined(arm64):
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

  proc idctPass1Neon*(tmpP, midP, cosP, cfacP: ptr float64) =
    ## First IDCT pass: `mid[y][x] += (Cfac[u] * tmp[y][u]) * CosT[u][x]`.
    for y in 0..7:
      for u in 0..7:
        var kk = [f64p(cfacP, u)[] * f64p(tmpP, y*8+u)[], 0.0]
        kk[1] = kk[0]
        let kv = vld1q_f64(addr kk[0])
        var i = 0
        while i < 8:
          let d = vld1q_f64(f64p(midP, y*8+i))
          let t = vld1q_f64(f64p(cosP, u*8+i))
          vst1q_f64(f64p(midP, y*8+i), vaddq_f64(d, vmulq_f64(t, kv)))
          i += 2

  proc idctPass2Neon*(midP, outP, cosP, cfacP: ptr float64) =
    ## Second IDCT pass: `out[y][x] += (Cfac[v] * mid[v][x]) * CosT[v][y]`.
    for y in 0..7:
      for v in 0..7:
        var cc = [f64p(cfacP, v)[], 0.0]
        var tt = [f64p(cosP, v*8+y)[], 0.0]
        cc[1] = cc[0]; tt[1] = tt[0]
        let cv = vld1q_f64(addr cc[0])
        let tv = vld1q_f64(addr tt[0])
        var i = 0
        while i < 8:
          let d = vld1q_f64(f64p(outP, y*8+i))
          let m = vld1q_f64(f64p(midP, v*8+i))
          vst1q_f64(f64p(outP, y*8+i),
            vaddq_f64(d, vmulq_f64(vmulq_f64(m, cv), tv)))
          i += 2

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
