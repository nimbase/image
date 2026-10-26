## PNG Up-filter kernel, ARM NEON (16 bytes per iteration).
## All Apple Silicon and modern ARM64 chips have NEON; still reached only
## through the runtime dispatcher in `image/simd` with a scalar fallback.
when defined(arm64):
  import nimsimd/neon

  proc upRowNeon*(curP, prevP: ptr uint8, n16: int) =
    ## Adds `prevP[0..<n16]` into `curP[0..<n16]`; `n16` must be a
    ## multiple of 16.
    var i = 0
    while i < n16:
      let a = vld1q_u8(cast[pointer](cast[int](curP) + i))
      let b = vld1q_u8(cast[pointer](cast[int](prevP) + i))
      vst1q_u8(cast[pointer](cast[int](curP) + i), vaddq_u8(a, b))
      i += 16
