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
