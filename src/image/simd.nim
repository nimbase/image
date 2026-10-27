## Runtime-dispatched SIMD for image decoding (see plans/08-simd-acceleration.md).
##
## Contract: every dispatched path is bit-identical to its scalar oracle.
## x86_64 uses SSE2 always (ABI baseline) and AVX2 when `runtimecheck`
## reports it; arm64 uses NEON. Unknown PNG filters return false so callers
## can raise `bad filter`. Small PNG rows (< 16 bytes) stay scalar to avoid
## setup cost.
##
## FP-contract note: ARM64 always has FMA, so without this flag Clang/GCC
## fuse scalar `a*b+c` into one rounding while the NEON/SSE/AVX intrinsics
## below stay two roundings (off-by-one after int truncation). Disabled so
## oracle and kernels round identically on all arches.
when defined(gcc) or defined(clang):
  {.localPassc: "-ffp-contract=off".}

import std/math
import ./simd/x86_sse2

when defined(amd64):
  import nimsimd/runtimecheck
  import ./simd/x86_avx2
  let useAvx2* = checkInstructionSets({AVX2})
else:
  let useAvx2* = false

when defined(arm64):
  import ./simd/arm_neon
  let useNeon* = true
else:
  let useNeon* = false

proc paeth*(a, b, c: int): int =
  let p = a + b - c
  let pa = abs(p - a); let pb = abs(p - b); let pc = abs(p - c)
  if pa <= pb and pa <= pc: a elif pb <= pc: b else: c

proc ycbcrToRgb*(y, cb, cr: uint8): tuple[r, g, b: uint8] =
  ## Scalar YCbCr converter (JFIF levels). Vectorized row paths must match
  ## this exactly, including op grouping and truncation.
  let fY = float64(y); let fCb = float64(cb) - 128.0; let fCr = float64(cr) - 128.0
  (uint8(clamp(int(fY + 1.402 * fCr + 0.5), 0, 255)),
   uint8(clamp(int(fY - 0.344136 * fCb - 0.714136 * fCr + 0.5), 0, 255)),
   uint8(clamp(int(fY + 1.772 * fCb + 0.5), 0, 255)))

proc u8p(p: ptr uint8, i: int): ptr uint8 {.inline.} =
  cast[ptr uint8](cast[int](p) + i)

proc ycbcrRowScalar*(yP, cbP, crP, rgbP: ptr uint8, n: int) =
  ## Scalar oracle: planar Y/Cb/Cr rows to interleaved RGB bytes.
  let Y = cast[ptr UncheckedArray[uint8]](yP)
  let Cb = cast[ptr UncheckedArray[uint8]](cbP)
  let Cr = cast[ptr UncheckedArray[uint8]](crP)
  let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
  for i in 0..<n:
    let (r, g, b) = ycbcrToRgb(Y[i], Cb[i], Cr[i])
    Rgb[3*i] = r; Rgb[3*i+1] = g; Rgb[3*i+2] = b

proc ycbcrRowSimd*(yP, cbP, crP, rgbP: ptr uint8, n: int) =
  ## YCbCr row converter with runtime dispatch. Fully parallel per pixel.
  if n <= 0: return
  when defined(amd64):
    if useAvx2 and n >= 8:
      let m = (n div 4) * 4
      ycbcrRowAvx(yP, cbP, crP, rgbP, m)
      let m2 = ((n - m) div 2) * 2
      if m2 > 0:
        ycbcrRowSse2(u8p(yP, m), u8p(cbP, m), u8p(crP, m), u8p(rgbP, m*3), m2)
      for i in (m + m2)..<n:
        let (r, g, b) = ycbcrToRgb(
          cast[ptr UncheckedArray[uint8]](yP)[i],
          cast[ptr UncheckedArray[uint8]](cbP)[i],
          cast[ptr UncheckedArray[uint8]](crP)[i])
        let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
        Rgb[3*i] = r; Rgb[3*i+1] = g; Rgb[3*i+2] = b
    else:
      let m = (n div 2) * 2
      if m > 0: ycbcrRowSse2(yP, cbP, crP, rgbP, m)
      for i in m..<n:
        let (r, g, b) = ycbcrToRgb(
          cast[ptr UncheckedArray[uint8]](yP)[i],
          cast[ptr UncheckedArray[uint8]](cbP)[i],
          cast[ptr UncheckedArray[uint8]](crP)[i])
        let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
        Rgb[3*i] = r; Rgb[3*i+1] = g; Rgb[3*i+2] = b
  elif defined(arm64):
    let m = (n div 2) * 2
    if m > 0: ycbcrRowNeon(yP, cbP, crP, rgbP, m)
    for i in m..<n:
      let (r, g, b) = ycbcrToRgb(
        cast[ptr UncheckedArray[uint8]](yP)[i],
        cast[ptr UncheckedArray[uint8]](cbP)[i],
        cast[ptr UncheckedArray[uint8]](crP)[i])
      let Rgb = cast[ptr UncheckedArray[uint8]](rgbP)
      Rgb[3*i] = r; Rgb[3*i+1] = g; Rgb[3*i+2] = b
  else:
    ycbcrRowScalar(yP, cbP, crP, rgbP, n)

proc unfilterRowScalar*(filter: uint8, cur, prev: var seq[uint8],
    bpp: int): bool =
  ## Scalar reference and fallback. All SIMD paths must match this exactly.
  case filter
  of 0: true
  of 1: # Sub
    for i in bpp..<cur.len: cur[i] = uint8((int(cur[i]) + int(cur[i-bpp])) and 0xFF)
    true
  of 2: # Up
    for i in 0..<cur.len: cur[i] = uint8((int(cur[i]) + int(prev[i])) and 0xFF)
    true
  of 3: # Average
    for i in 0..<cur.len:
      let a = if i >= bpp: int(cur[i-bpp]) else: 0
      cur[i] = uint8((int(cur[i]) + (a + int(prev[i])) div 2) and 0xFF)
    true
  of 4: # Paeth
    for i in 0..<cur.len:
      let a = if i >= bpp: int(cur[i-bpp]) else: 0
      let b = int(prev[i])
      let c = if i >= bpp: int(prev[i-bpp]) else: 0
      cur[i] = uint8((int(cur[i]) + paeth(a, b, c)) and 0xFF)
    true
  else: false

proc simdUnfilterRow*(filter: uint8, cur, prev: var seq[uint8],
    bpp: int): bool =
  ## Drop-in replacement for the scalar row filter with runtime dispatch.
  ## Only the Up filter currently has SIMD kernels (fully parallel);
  ## Sub/Average/Paeth have intra-row dependencies and stay scalar for now.
  if cur.len != prev.len or cur.len == 0:
    if filter <= 4 and cur.len == prev.len: return true
    return filter <= 4
  if filter == 2'u8 and cur.len >= 16:
    let n = cur.len
    let curP = addr cur[0]
    let prevP = addr prev[0]
    when defined(amd64):
      if useAvx2 and n >= 32:
        let m = (n div 32) * 32
        upRowAvx2(curP, prevP, m)
        let m2 = ((n - m) div 16) * 16
        if m2 > 0:
          upRowSse2(cast[ptr uint8](cast[int](curP) + m),
            cast[ptr uint8](cast[int](prevP) + m), m2)
        for i in (m + m2)..<n:
          cur[i] = uint8((int(cur[i]) + int(prev[i])) and 0xFF)
      else:
        let m = (n div 16) * 16
        upRowSse2(curP, prevP, m)
        for i in m..<n:
          cur[i] = uint8((int(cur[i]) + int(prev[i])) and 0xFF)
    elif defined(arm64):
      let m = (n div 16) * 16
      upRowNeon(curP, prevP, m)
      for i in m..<n:
        cur[i] = uint8((int(cur[i]) + int(prev[i])) and 0xFF)
    else:
      return unfilterRowScalar(filter, cur, prev, bpp)
    return true
  unfilterRowScalar(filter, cur, prev, bpp)

# ---------- JPEG DCT helpers ----------

var JpegCosT*: array[8, array[8, float64]]
var JpegCfac*: array[8, float64]

proc initJpegTables() =
  for u in 0..7:
    JpegCfac[u] = if u == 0: 0.3535533905932738 else: 0.5
    for x in 0..7:
      JpegCosT[u][x] = cos((2.0 * float64(x) + 1.0) * float64(u) * PI / 16.0)

initJpegTables()

proc fptr(p: ptr float64, i: int): ptr float64 {.inline, used.} =
  cast[ptr float64](cast[int](p) + i * sizeof(float64))

proc idctPass1*(tmpP, midP, cosP, cfacP: ptr float64) {.inline.} =
  ## First IDCT pass, dispatched to the best backend.
  when defined(amd64):
    if useAvx2: idctPass1Avx(tmpP, midP, cosP, cfacP)
    else: idctPass1Sse2(tmpP, midP, cosP, cfacP)
  elif defined(arm64):
    idctPass1Neon(tmpP, midP, cosP, cfacP)
  else:
    for y in 0..7:
      for u in 0..7:
        let k = fptr(cfacP, u)[] * fptr(tmpP, y*8+u)[]
        for i in 0..7:
          fptr(midP, y*8+i)[] = fptr(midP, y*8+i)[] + k * fptr(cosP, u*8+i)[]

proc idctPass2*(midP, outP, cosP, cfacP: ptr float64) {.inline.} =
  ## Second IDCT pass, dispatched to the best backend.
  when defined(amd64):
    if useAvx2: idctPass2Avx(midP, outP, cosP, cfacP)
    else: idctPass2Sse2(midP, outP, cosP, cfacP)
  elif defined(arm64):
    idctPass2Neon(midP, outP, cosP, cfacP)
  else:
    for y in 0..7:
      for v in 0..7:
        let c = fptr(cfacP, v)[]
        let t = fptr(cosP, v*8+y)[]
        for i in 0..7:
          fptr(outP, y*8+i)[] = fptr(outP, y*8+i)[] +
            (c * fptr(midP, v*8+i)[]) * t

proc fdctPass1*(pxP, midP, cosP, cfacP: ptr float64) {.inline.} =
  ## First FDCT pass (plus row scaling), dispatched to the best backend.
  when defined(amd64):
    if useAvx2: fdctPass1Avx(pxP, midP, cosP, cfacP)
    else: fdctPass1Sse2(pxP, midP, cosP, cfacP)
  elif defined(arm64):
    fdctPass1Neon(pxP, midP, cosP, cfacP)
  else:
    for v in 0..7:
      for y in 0..7:
        let k = fptr(cosP, v*8+y)[]
        for i in 0..7:
          fptr(midP, v*8+i)[] = fptr(midP, v*8+i)[] +
            k * fptr(pxP, y*8+i)[]
      for i in 0..7:
        fptr(midP, v*8+i)[] = fptr(midP, v*8+i)[] * fptr(cfacP, v)[]

proc fdctPass2*(midP, resP, cosP, cfacP: ptr float64) {.inline.} =
  ## Second FDCT pass, dispatched to the best backend. Products accumulate
  ## into a temp row summed in scalar order, preserving exact accumulation.
  when defined(amd64):
    if useAvx2: fdctPass2Avx(midP, resP, cosP, cfacP)
    else: fdctPass2Sse2(midP, resP, cosP, cfacP)
  elif defined(arm64):
    fdctPass2Neon(midP, resP, cosP, cfacP)
  else:
    var acc: array[8, float64]
    for v in 0..7:
      for u in 0..7:
        for i in 0..7: acc[i] = 0.0
        for i in 0..7:
          acc[i] += fptr(midP, v*8+i)[] * fptr(cosP, u*8+i)[]
        var s = 0.0
        for x in 0..7: s += acc[x]
        fptr(resP, v*8+u)[] = s * fptr(cfacP, u)[]

proc idctBlockScalar*(coef: array[64, float64],
    qt: array[64, int]): array[64, uint8] =
  ## Scalar oracle: separable float IDCT with dequant. Vectorized paths must
  ## match this exactly (same op order per element).
  var tmp: array[64, float64]
  for i in 0..63: tmp[i] = coef[i] * float64(qt[i])
  var mid: array[64, float64]
  for y in 0..7:
    for x in 0..7:
      var s = 0.0
      for u in 0..7: s += JpegCfac[u] * tmp[y*8+u] * JpegCosT[u][x]
      mid[y*8+x] = s
  for y in 0..7:
    for x in 0..7:
      var s = 0.0
      for v in 0..7: s += JpegCfac[v] * mid[v*8+x] * JpegCosT[v][y]
      result[y*8+x] = uint8(clamp(int(s + 128.5), 0, 255))

proc idctBlockSimd*(coef: array[64, float64],
    qt: array[64, int]): array[64, uint8] =
  ## Vectorized IDCT. Pass 1 scales rows by one scalar per (y, u); pass 2
  ## uses the `(c * m) * t` form to preserve the scalar multiply grouping.
  var tmp: array[64, float64]
  for i in 0..63: tmp[i] = coef[i] * float64(qt[i])
  var mid: array[64, float64]
  var outp: array[64, float64]
  let cosP = cast[ptr float64](addr JpegCosT[0][0])
  let cfacP = cast[ptr float64](addr JpegCfac[0])
  idctPass1(cast[ptr float64](addr tmp[0]), cast[ptr float64](addr mid[0]),
    cosP, cfacP)
  idctPass2(cast[ptr float64](addr mid[0]), cast[ptr float64](addr outp[0]),
    cosP, cfacP)
  for i in 0..63:
    result[i] = uint8(clamp(int(outp[i] + 128.5), 0, 255))

proc fdctBlockScalar*(px: array[64, float64]): array[64, float64] =
  ## Scalar oracle for the forward DCT.
  var mid: array[64, float64]
  for v in 0..7:
    for x in 0..7:
      var s = 0.0
      for y in 0..7: s += px[y*8+x] * JpegCosT[v][y]
      mid[v*8+x] = s * JpegCfac[v]
  for v in 0..7:
    for u in 0..7:
      var s = 0.0
      for x in 0..7: s += mid[v*8+x] * JpegCosT[u][x]
      result[v*8+u] = s * JpegCfac[u]

proc fdctBlockSimd*(px: array[64, float64]): array[64, float64] =
  ## Vectorized FDCT. Pass 2 accumulates products into a temp row that is
  ## then summed in scalar order, preserving the exact accumulation.
  var mid: array[64, float64]
  let cosP = cast[ptr float64](addr JpegCosT[0][0])
  let cfacP = cast[ptr float64](addr JpegCfac[0])
  fdctPass1(cast[ptr float64](addr px[0]), cast[ptr float64](addr mid[0]),
    cosP, cfacP)
  fdctPass2(cast[ptr float64](addr mid[0]), cast[ptr float64](addr result[0]),
    cosP, cfacP)
