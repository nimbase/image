# Architecture

Pure-Nim port of the Rust [`image`](https://github.com/image-rs/image)
crate (v0.25.9), mirroring its API (`DynamicImage`, `ImageBuffer`,
`ImageReader`, `ImageFormat`). Zero C bindings: deflate comes from the
pure-Nim `pkg/archive` library; LZW is hand-rolled (`lzw.nim`, shared by
GIF/TIFF). `imageops` processing functions are out of scope for v1.

## Layout

```text
src/
  image.nim            # facade: imports + re-exports every module below
  image/
    color.nim          # pixels (Rgb/Rgba/Luma/LumaA), ColorType, sRGB
    buffer.nim         # ImageBuffer + 12 named aliases
    dynamic.nim        # DynamicImage (12 variants), dimensions, cropImage
    format.nim         # ImageFormat (15 variants), fromExtension/MimeType
    reader.nim         # guessFormat (magic bytes)
    io.nim             # byte-level IO helpers
    decoder.nim        # decoder/encoder concepts, format attributes
    animation.nim      # Frame, Delay, LoopCount (no processing)
    metadata.nim       # Orientation, EXIF/IPTC/XMP hooks
    error.nim          # ImageError / ImageResult[T]
    limits.nim         # Limits (default 512 MiB alloc cap)
    lzw.nim            # pure-Nim LZW
    math.nim           # clamp, YCbCr helpers used by the converter
    convert.nim        # decodeImage, normalizeToRgba8, convertToWebp, WebpRequest
    endian.nim         # endian helpers
    zlibwrap.nim       # deflate bridge to pkg/archive
    simd.nim           # runtime-dispatched SIMD (scalar fallback is bit-identical)
    simd/              # per-arch kernels
    codecs/            # one module per format (see codecs.md)
```

## Data flow

```text
seq[uint8] --guessFormat--> ImageFormat --decodeX--> DynamicImage
DynamicImage --encodeX--> seq[uint8]
seq[uint8] --decodeImage--> DynamicImage --convertToWebp--> seq[uint8] (WebP)
```

- Detection is magic-byte based (`reader.guessFormat`), never extension based.
- The canonical in-memory value is `DynamicImage` (see [core](core.md)).
- Multi-image inputs (animated GIF, multi-page TIFF, multi-image ICO,
  EXR multi-part) decode to first-frame-only by default; the `*All`
  variants (`decodeTiffAll`, `decodeIcoAll`, `decodeExrAll`) return all.
- `ok()` uses `sink` ownership: storing a pixel buffer into a result does
  not copy it (matters for multi-megapixel peak memory).
- SIMD (`simd.nim` + `simd/`) accelerates PNG unfilter rows, JPEG IDCT/FDCT,
  and YCbCr rows via `nimsimd` runtime dispatch (SSE2/AVX2/NEON); the scalar
  fallback is bit-identical. PNG Average/Paeth/Sub stay scalar by design.

## Dependencies

- `archive` (pure-Nim inflate/deflate/CRC32) — runtime, required.
- `nimsimd` — runtime, required (SIMD kernels + scalar fallback).
- No C bindings anywhere in the dependency closure of the library itself.
