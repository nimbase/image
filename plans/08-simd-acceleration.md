# 08 — SIMD-accelerated decoding (nimsimd)

Decisions (user-confirmed):
- Dispatch: automatic at runtime when SIMD is available, scalar fallback always.
- First target: PNG `unfilterRow` (Up, then Average, Paeth, Sub).
- Must cover Apple Silicon (ARM NEON) as well as x86_64, even though
  nimsimd NEON bindings are experimental.

## Background

- `nimsimd` (guzba/nimsimd) provides Nim bindings for SSE up to AVX2 + FMA,
  plus `nimsimd/runtimecheck` for CPU feature detection.
- x86 backends need per-file `{.localPassc: "-msse4.2".}` (or avx2) flags.
- NEON path must be guarded with `when defined(arm64)` and always have a
  scalar fallback; if nimsimd/neon lacks an intrinsic, hand-roll via `{.emit.}`.
- Constraint: decode output must stay bit-identical to scalar.

## Design

```
src/image/simd.nim            # dispatcher + cached feature detection
src/image/simd/simdpng_sse.nim   # SSE4.1/AVX2 row kernels (localPassc)
src/image/simd/simdpng_neon.nim  # NEON row kernels (arm64 only)
src/image/codecs/png.nim      # calls simd dispatcher, scalar stays as oracle
```

- `simd.nim` exposes `simdUnfilterRow(filter, cur, prev, bpp): bool`
  returning false when filter unknown so caller can raise `bad filter`.
- Detection cached once: `let feats = checkInstructionSets({SSE2, SSE41, AVX2})`
  on x86; on arm64 assume NEON with runtime gate.
- Row length threshold: use SIMD only when `rowBytes >= 32`, else scalar
  (avoids setup overhead on tiny rows).

## PNG kernel order

1. Up (`cur[i] += prev[i]`): fully parallel, 16B (SSE) / 16B (NEON) chunks.
2. Average: seed first `bpp` bytes scalar, then SIMD over the rest using
   already-reconstructed `cur[i-bpp]`.
3. Paeth: vector `p = a+b-c` formulation with min/max/clamp; validate vs scalar.
4. Sub: stride dependency; SIMD only for the steady-state tail, scalar warmup.

## Correctness

- New test `tests/t_simd_png.nim`: random rows x filters x bpp,
  row lengths 1..256, SIMD result byte-equal to scalar oracle.
- New test `tests/t_simd_jpeg.nim`: random + sparse coef blocks and pixel
  blocks, SIMD IDCT/FDCT bit-equal to scalar oracle (exact op order).
- Existing `tests/t_png.nim`, `t_jpeg.nim` pass unmodified (integration).
- All tests run with `-d:release` (`clue test -d:release`), forwarded to nim.

## Measured results (x86_64, AVX2)

- PNG Up 16 KB row x200, release: scalar 0.00322s vs SIMD 0.000995s (~3.2x).
  Holds in both debug (~3.6x) and release. Byte kernel = clear win.
- JPEG IDCT x2000 blocks, release: scalar 0.000707s vs SIMD 0.000737s
  (parity). Debug: SIMD ~1.8x ahead. The separable-dot loop shape
  auto-vectorizes fully under -O3; per-row broadcasts add overhead the
  compiler avoids. Whole-pass kernels (one dispatch per pass) did not
  change the picture. Verdict: keep the exact path (debug win, ARM
  unknown), do NOT chase this further on x86_64 release.
- Lesson: target kernels the compiler cannot reach (byte shuffles,
  gathers, wide row batches), not f64 dot products it already owns.

## Risks

- nimsimd NEON experimental: mitigate with scalar fallback + arm64 CI check.
- nimsimd 1.3.2 (pinned) NEON module lacks ALL f64 load/store/arithmetic
  (present on master). Added 4 local importc bindings in `simd/arm_neon.nim`;
  validated with `nim check --cpu:arm64`. Revisit on nimsimd upgrade.
- Compiler flags leaking: keep flags local to simd backend files only.
- Pure-Nim story: nimsimd is still Nim-only bindings (no C lib), same as zlib
  exception rationale; document in README.

## Phases after PNG

- Phase 2: JPEG IDCT (FMA/AVX) + YCbCr to RGB batches of 8/16 px.
  IDCT done (exact, parity in release x86_64 — see Measured results).
  YCbCr batching still open: better profile (per-pixel, no reduction,
  full-image loop) but needs assembly-loop restructure in jpgdec.
- Phase 3: shared YUV/color-math batch paths (AVIF/JPEG/TIFF).
- VP8L predictors explicitly deferred (sequential byte dependency, poor fit).
