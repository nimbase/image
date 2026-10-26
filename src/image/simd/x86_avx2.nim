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
