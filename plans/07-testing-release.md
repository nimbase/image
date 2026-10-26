# 07 — Testing & Release (no imageops)

## 7.1 Unit tests (per module, `tests/t_*.nim`, run via `clue test`)

- `t_color`: lossless u8<->u16, f32 NaN handling, rgbToLuma `13,13,13 -> 13`,
  blend/invert vectors from `color.rs:999-1134`.
- `t_format`: table from `io/format.rs:324-355` (jpg/jpeg/jfif, png/apng, gif,
  webp, tif/tiff, tga, bmp, ico, hdr, exr, pbm/pam/ppm/pgm/pnm, ff, qoi, avif),
  mime round-trip, `fromPath` error on `.txt`/no-ext.
- `t_limits`: default 512MiB, `reserve`/`free`, dimension overflow
  (`decoder.rs:335` total_bytes_overflow test).
- `t_buffer`: put/get, checked OOB, cropInPlace, `fromRaw` length mismatch.
- Per-codec: reference decode + encode->decode pixel equality.
  Sources: `references/image/tests/images/**`, `tests/reference/*`.

## 7.2 Reference / regression suites (port from Rust)

- `tests/reference_images.rs` -> `tests/t_reference.nim`: iterate checked-in
  images, decode, compare against `.png` ground truth where applicable.
- `tests/regression.rs`, `tests/bad_images.rs`, `tests/truncate_images.rs`:
  truncated input must yield `DecodingError`, never panic/index defect.
- `tests/limits*.rs`, `tests/metadata.rs`, `tests/conversions.rs`,
  `tests/save_pnm.rs`, `tests/save_jpeg.rs`: port as applicable.
- Fuzz seeds: `fuzz/`, `fuzz-afl/` corpora reused as regression inputs.

## 7.3 Benches (optional, after correctness)

`benches/decode.rs`, `encode.rs`, `copy_from.rs`, `convert.rs` ->
`nimble` tasks measuring PNG/JPEG decode MB/s. No criterion dep; use
`std/monotimes` + simple harness.

## 7.4 `image.nimble` + CI

```nimble
requires "nim >= 2.2.0"
requires "zlib >= 0.1.0"   # only non-stdlib dep allowed
srcDir = "src"
```

Tasks: `test` (clue test), `reference` (long suite, nightly only).
Lint: `clue check`, `clue doctor` before each PR.
Docs: `clue docs.gen` for public API (`DynamicImage`, `ImageFormat`, codecs).

## 7.5 Definition of done (v1, processing excluded)

- Core + Tier 1 + Tier 2 green, Tier 3 JPEG/WebP/EXR green, AVIF clean
  `Unsupported` + YUV helpers green.
- `tests/images` reference suite passes; truncated/bad inputs error cleanly.
- No `imageops` symbols exported; README states processing excluded.
- `plans/*.md` + Nim doc comments reference original Rust file + line for
  each ported proc.
