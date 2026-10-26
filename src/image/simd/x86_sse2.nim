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
