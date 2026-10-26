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

- New test `tests/t_simd_png.nim`: random rows x filters (0-4) x bpp (1,2,3,4,6,8),
  row lengths 1..256, SIMD result byte-equal to scalar oracle.
- Existing `tests/t_png.nim` must pass unmodified (integration via real files).
- Fuzz: reference PNG corpus decode must stay green.

## Performance

- Bench harness (temporary, not committed... or committed under tests/bench?):
  4K RGBA row, each filter, scalar ns/row vs SIMD ns/row, printed table.
- Success bar for Phase 1: Up >= 3x scalar on x86_64; no regression on arm64.

## Risks

- nimsimd NEON experimental: mitigate with scalar fallback + arm64 CI check.
- Compiler flags leaking: keep flags local to simd backend files only.
- Pure-Nim story: nimsimd is still Nim-only bindings (no C lib), same as zlib
  exception rationale; document in README.

## Phases after PNG

- Phase 2: JPEG IDCT (FMA/AVX) + YCbCr to RGB batches of 8/16 px.
- Phase 3: shared YUV/color-math batch paths (AVIF/JPEG/TIFF).
- VP8L predictors explicitly deferred (sequential byte dependency, poor fit).
