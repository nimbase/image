# webp_convert — any image to WebP

`webp_convert input output [--quality N] [--lossless]` converts any
supported image to WebP using the pure-Nim `image` library.

## Build

```sh
cd examples/webp_convert
clue build --release
./bin/webp_convert photo.jpg photo.webp --quality 75
```

Always use `--release`: the pure-Nim encoders are slow in debug builds
(a 24 MP JPEG decodes in ~19 s even in release; lossless VP8L on top).

## Use

```sh
webp_convert photo.png photo.webp            # lossy q75 (default)
webp_convert photo.jpg photo.webp -q 90      # lossy q90
webp_convert photo.tiff photo.webp --lossless  # VP8L lossless
```

Prints `input (WxH) -> output (bytes, mode, time)`. Exit non-zero with
a message on stderr for unreadable input, unknown format, bad quality,
or write failures.

## Formats

Input is sniffed from magic bytes: PNG, JPEG, GIF (first frame only),
WebP, BMP, TIFF, TGA, PNM, ICO, QOI, HDR, OpenEXR, Farbfeld, AVIF,
HEIF/HEIC. 16-bit and float sources auto-downconvert to 8-bit (HDR
clamps, no tone mapping in v1). Partially supported sources (EXR PIZ,
HEIF video/J2K, animated WebP) report the decoder's clean error.

## Notes

- Lossless output is large: the VP8L encoder is literal-only (no LZ77,
  transforms, or color cache), so a 24 MP photo is ~70 MB. It is still
  pixel-exact and decodes in any spec WebP decoder.
- Lossy default quality is 75 (cwebp default); quality maps linearly to
  the VP8 quantizer index.
