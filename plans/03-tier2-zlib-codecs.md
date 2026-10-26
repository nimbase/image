# 03 — Tier 2 Zlib Codecs (png, gif, tiff, ico)

Allowed dep: `pkg/zlib` (wraps C zlib) for inflate/deflate only.
Everything else pure Nim. LZW (GIF/TIFF) must be hand-ported, not via zlib.

## 3.0 Shared: `src/image/zlib.nim` + `lzw.nim`

- `zlib.nim`: thin wrapper over `pkg/zlib`: `inflate(data, expectedSize, limits)`,
  `deflate(data, level)`, streaming for IDAT. Map zlib errors -> `DecodingError`.
- `lzw.nim`: GIF-style LSB-first variable-width codes (clear/eoi, 9..12 bit)
  + TIFF-style MSB-first + horizontal predictor. Port from `image-gif` and
  `image-tiff` decoders, not from C.
- `adlerCrc.nim`: adler32 + crc32 pure Nim (needed for PNG chunk CRC when
  zlib pkg does not expose it).

## 3.1 PNG (`codecs/png.rs:1183` + external `png@0.18.0` to clone)

Reference clone: `references/png` (image-rs/image-png).
Port from both: facade in `image/src/codecs/png.rs` + real logic in
`png/src/{decoder,encoder,filter,adam7}.rs`.

Scope:
- Signature 8B, IHDR (w/h/bitdepth/colortype/compression/filter/interlace),
  PLTE/tRNS, IDAT concat -> inflate via `pkg/zlib`, unfilter (None/Sub/Up/
  Average/Paeth, per-scanline), Adam7 deinterlace (7 passes), APNG
  (fcTL/fdAT as sequence frames -> `animation.nim`).
- Color: L1/L2/L4/L8/L16, La, Rgb, Rgba, palette -> expand. 16-bit BE.
- Encoder: filter selection (heuristic or Sub default), deflate level map,
  text chunks (iTXt/zTXt for XMP), ICC (iCCP).
- Metadata: `iccProfile/exif/xmp/iptc` from text/eXIf chunks.
- Limits: `png::Limits{bytes}` <- `Limits.maxAlloc`.

## 3.2 GIF (`codecs/gif.rs:684` + external `gif@0.14.1`)

Reference clone: `references/gif` (image-rs/image-gif).
- Header `GIF87a/89a`, LSD, GCT, extensions (GCE, App Netscape loop, XMP),
  image descriptors, interlaced 4-pass, LZW decode (pure Nim `lzw.nim`),
  disposal methods -> `DecodedImageAttributes(x,y,delay)`.
- Encoder: `gif::Encoder`, palette quantization (no `color_quant` dep;
  port median-cut or NeuQuant inline), loop count.
- Animation: `Frames` iterator, `LoopCount`.

## 3.3 TIFF (`codecs/tiff.rs:849` + external `tiff@0.11.2`)

Reference clone: `references/tiff` (image-rs/image-tiff).
- Header II/MM + magic 42, IFD chain, tags (Width/Height/Photometric/
  Compression/SamplesPerPixel/RowsPerStrip/Tile*/Predictor/ICC/EXIF/XMP),
  types SHORT/LONG/RATIONAL/ASCII/UNDEFINED.
- Compression: None, LZW (pure Nim), Deflate (via `pkg/zlib`), PackBits,
  JPEG-in-TIFF (delegate to jpeg.nim). Fax/CCITT -> `Unsupported` initially.
- Photometric: WhiteIsZero/BlackIsZero/RGB/RGBA/YCbCr (use ycbcr->rgb from jpeg).
- Multi-page: `moreImages/nextImage` sequence.
- Encoder: baseline single-strip encode first, then tiled.

## 3.4 ICO (`codecs/ico/: decoder 705, encoder`)

- ICONDIR (reserved/type/count) + ICONDIRENTRY (w/h single-byte 0=256,
  planes/bitcount/size/offset), embedded BMP (without file header) or PNG.
- Delegate payload to `bmp.nim` / `png.nim`. Multi-image: largest/best match.
- Encoder: PNG-compressed entries preferred.

## Acceptance

- Reference suites: `tests/reference_images.rs`, `tests/images/{png,gif,tiff,ico}/**`.
- PNG: Paeth + Adam7 vectors must pass exactly.
- Round-trip lossless for non-paletted paths; `truncate_images.rs` behavior
  (UnexpectedEof -> DecodingError, not panic).
