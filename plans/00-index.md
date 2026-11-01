# Nim `image` — Pure-Nim Port Plan (mirror of `references/image`)

Target: `/Users/georgelemon/Development/nimbase/packages/image`
Reference: `/Users/georgelemon/Development/nimbase/references/image` (v0.25.9)
Constraints (user-confirmed):
- Mirror Rust API: `DynamicImage`, `ImageBuffer`, `ImageReader`, `ImageFormat`, traits as Nim concepts.
- Pure Nim, zero C, except `pkg/zlib` allowed for deflate/inflate.
- Full parity: all 14 `ImageFormat` variants.

## Layout of this plan

- `01-core-foundation.md` — color, error, traits, buffer, dynamic, io, format. Do first.
- `02-tier1-simple-codecs.md` — farbfeld, qoi, pnm, tga, hdr, bmp. Self-contained, no zlib.
- `03-tier2-zlib-codecs.md` — png, gif, tiff, ico. Needs `pkg/zlib` + pure-Nim LZW.
- `04-tier3-complex-codecs.md` — jpeg, webp, openexr, avif. Largest work.
- `05-external-crates.md` — what to clone into `references/` and what to port from each.
- `06-imageops-math-metadata.md` — EXCLUDED for now (processing functions out of
  scope). Only minimal `math.Rect` + `metadata` needed by codecs are in scope.
  See `06-excluded-imageops.md`.
- `07-testing-release.md` — testing, fuzz, benches, CI, nimble tasks.
- `08-simd-acceleration.md` — runtime-dispatched SIMD via nimsimd (PNG first).
- `09-heif.md` — HEIF/HEIC container + uncompressed/JPEG-in-HEIF decode (clean-room,
  spec-based; libheif is black-box oracle only, never ported; VVC/AVC/JPEG2000
  decode stays Unsupported).
- `10-jpeg-crop-compress.md` — fluent JPEG compression request builder
  (`compress().crop().encode()`), strict variant-preserving `cropImage`
  (deliberate imageops scope exception), standard 8-bit input policy, and
  optional optimized Huffman encoding (djpeg-validated, sentinel avoids
  all-ones codewords).
- `11-jpeg-decode-perf.md` — ordered JPEG decode speed plan (24 MP
  progressive is ~19 s release): profile first, scaled IDCT, fast
  integer IDCT + SIMD, Huffman/bit-reader, DC-only preview, threads
  deferred.
- `12-memory-footprint.md` — peak-memory reduction: pipeline map,
  Nim value-semantics copy rules (measured), per-case before/after
  ru_maxrss table, deferred items with rationale.
- `13-webp-converter.md` — any-supported-format → WebP converter
  (decode dispatcher, input normalization, `convertToWebp` + fluent
  `WebpRequest`, new VP8 lossy encoder).

## Proposed Nim module tree

```
src/image.nim                 # re-exports, open/load/save, write_to
src/image/
  color.nim                   # ColorType, ExtendedColorType, Rgb/Rgba/Luma/LumaA
  error.nim                   # ImageError, *Error, ImageResult[T]
  traits.nim                  # Primitive, Pixel, Enlargeable concepts
  buffer.nim                  # ImageBuffer[P], GrayImage, RgbImage aliases
  dynamic.nim                 # DynamicImage variant object + conversions
  flat.nim                    # FlatSamples (from images/flat.rs:2118 LOC)
  generic.nim                 # GenericImageView/Image concepts, SubImage
  io.nim                      # ImageLayout, DecoderPreparedImage
  decoder.nim                 # ImageDecoder concept + FormatAttributes etc.
  encoder.nim                 # ImageEncoder concept
  format.nim                  # ImageFormat + fromExtension/fromPath/fromMimeType
  reader.nim                  # ImageReader (from io/image_reader_type.rs:1123)
  limits.nim                  # Limits, LimitSupport
  freefuncs.nim               # load/save_buffer/guess_format
  animation.nim               # Delay, Frame, Frames
  math.nim                    # Rect only (needed by buffer crop, APNG offsets)
  metadata.nim                # Orientation, LoopCount, Cicp, exif/xmp stubs
  # NOTE: processing functions excluded for now — no imageops/
  # (affine, colorops, resize, sample, filter_1d, fast_blur intentionally omitted)
  codecs/
    farbfeld.nim, qoi.nim, pnm.nim, tga.nim, hdr.nim, bmp.nim
    png.nim, gif.nim, tiff.nim, ico.nim
    jpeg.nim, webp.nim, openexr.nim, avif.nim
```

## Build order

1. Core (Phase 0) — unblocks everything.
2. Tier 1 (Phase 1) — first green round-trips.
3. Tier 2 (Phase 2) — zlib integration.
4. Tier 3 (Phase 3) — behind `Unsupported` stubs until done.
5. imageops/metadata (can parallelize after core).
6. Hardening: limits, reference images, fuzz.

Toolchain: `clue build`, `clue test`. No `nim c` directly.
