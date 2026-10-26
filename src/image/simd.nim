## Runtime-dispatched SIMD for image decoding (see plans/08-simd-acceleration.md).
##
## Contract: every dispatched path is bit-identical to `unfilterRowScalar`.
## x86_64 uses SSE2 always (ABI baseline) and AVX2 when `runtimecheck`
## reports it; arm64 uses NEON. Unknown filters return false so callers can
## raise `bad filter`. Small rows (< 16 bytes) stay scalar to avoid setup cost.
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
