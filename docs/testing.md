# Testing

## Running tests

```sh
clue test              # full suite, debug (25 files, must all pass)
clue test -d:release  # full suite, release (required: SIMD paths differ)
clue test t_webp      # one file per invocation
```

Both modes must be green before pushing. Debug slowness is expected
(pure-Nim encoders); use `--release` for anything over ~1 MP.

## Layout

- `tests/t_<codec>.nim` — per-codec round-trips and edge cases.
- `tests/t_convert_webp.nim` — converter matrix (every encodable format,
  GIF frame-0, alpha, 16-bit/float downconvert, fluent bounds, lossy
  error bounds, empty/oversize rejects).
- `tests/t_crop_compress.nim` — JPEG fluent builder + strict crop.
- `tests/t_vp8.nim` / `t_vp8enc.nim` — VP8 lossy decode / encode.
- `tests/t_truncate.nim` — truncated-input robustness (must error, never raise).
- `tests/t_reference.nim` — vendored fixture corpus (45 fixtures).
- `tests/t_lzw.nim`, `t_simd_png.nim`, `t_simd_jpeg.nim` — shared units.
- `tests/fixtures/` — vendored binaries (see below).

## Oracles (behavioral, never ported code)

- WebP: `dwebp` CLI — our lossy decode is bit-exact vs dwebp; lossless
  output must also decode in `dwebp` (this caught two real encoder bugs:
  Kraft-invalid Huffman fallback and 3-bit `clLens` truncation).
- JPEG: reference decoders for baseline/progressive vectors.
- HEIF: `references/libheif` CLI tools generate fixtures only (LGPL
  boundary — black-box oracle, no code porting; see `plans/09-heif.md`).

## Fixtures

- `tests/fixtures/` is vendored data, including a 24 MP Unsplash photo
  used by the VP8L photo round-trip regression test. Large fixtures stay
  in-repo; profiling-only assets (phone photos, `/tmp/jpgprof/` outputs)
  stay out — see `benches/genjpgprof.nim`.
- When adding a regression test, prefer the smallest input that triggers
  the shape (e.g. the 1100² photo crop for deep Huffman trees) plus a
  synthetic unit (e.g. Fibonacci-skewed counts for Kraft validity).

## Adding a test

1. Round-trip: encode → decode → compare pixels (lossless) or bound the
   error (lossy, e.g. mean abs channel error thresholds in
   `t_convert_webp.nim`).
2. Truncation: feed cut-off bytes, assert `.ok == false`.
3. Clean errors: assert the right `kind` (`ekUnsupported` vs
   `ekDecoding`), never an exception.
