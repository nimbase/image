# 02 — Tier 1 Simple Codecs (first round-trips, no zlib)

All self-contained in `references/image/src/codecs/`. Port in this order:
qoi -> farbfeld -> pnm -> tga -> hdr -> bmp.

## Common Nim codec shape

```nim
type QoiDecoder*[S: Stream] = object
  s*: S; limits*: Limits; hdr*: ...; prepared*: bool
proc newQoiDecoder*[S](s: S): QoiDecoder[S]
proc prepareImage*(d: var QoiDecoder): ImageResult[DecoderPreparedImage]
proc readImage*(d: var QoiDecoder, buf: var openArray[uint8]): ImageResult[DecodedImageAttributes]
type QoiEncoder*[S: Stream] = object
  s*: S
proc writeImage*[S](e: QoiEncoder[S], buf: openArray[uint8], w, h: uint32, c: ExtendedColorType): ImageResult[void]
```

Use `streams.readUint16BE/writeUint16BE` helpers (new `src/image/endian.nim`
replacing `byteorder-lite`).

## 2.1 QOI (`codecs/qoi.rs:121` + external `qoi@0.4`)

- Magic `qoif`, 14-byte header (w,h u32BE, channels u8, colorspace u8).
- Opcodes: INDEX/RUN/DIFF/LUMA/RGB/RGBA. 64-entry index array.
- Encode + decode both. Only 8-bit Rgb8/Rgba8.
- Tests: `qoi` crate test vectors.

## 2.2 Farbfeld (`codecs/farbfeld.rs:186`)

- 8-byte magic `farbfeld`, w/h u32BE, then BE u16 RGBA rows.
- Trivial. Only Rgba16. Good first encoder/decoder to validate harness.

## 2.3 PNM (`codecs/pnm/: decoder 1582, encoder 774, header 366, autobreak`)

- Types: PBM P1/P4, PGM P2/P5, PPM P3/P6, PAM P7, plus `autobreak` compat.
- ASCII + binary paths, maxval 1..65535, tuples (RGB/RGBA/GRAYSCALE).
- Header parser must handle comments/whitespace exactly like `header.rs`.
- Tests: `tests/save_pnm.rs`, reference `tests/images/*.{pbm,pgm,ppm,pam}`.

## 2.4 TGA (`codecs/tga/: decoder 462, encoder 534, header`)

- Header 18B, colormap, RLE vs raw, BGR->RGB flip, bottom-left vs top-left origin,
  footer extension.
- Support L8/La8/Rgb8/Rgba8, 16-bit Rgb5x1 path -> Rgb8 expand.
- Tests: reference TGA images.

## 2.5 HDR (`codecs/hdr/: decoder 801, encoder 480`)

- Radiance RGBE: magic `#?RADIANCE`, `FORMAT=32-bit_rle_rgbe`,
  `EXPOSURE`, flat vs RLE scanlines, `rgbeToFloat`.
- Only Rgb32F. Port `toHdr/fromHdr` conversions.
- Tests: `tests/images/hdr/*`.

## 2.6 BMP (`codecs/bmp/: decoder 3170, encoder 750`)

Largest Tier 1. Do last.
- File header 14B + DIB (BITMAPCOREHEADER..BITMAPV5HEADER), top-down vs bottom-up,
  bitfields masks, RLE4/RLE8, 1/2/4/8-bit paletted, 16/24/32-bit, ICO-embedded path.
- Port `Bitfields`, palette expansion, `toIco` synthetic ICC hook.
- Encoder: 24/32-bit + paletted 1/4/8-bit.
- Tests: `examples/bmp_1bit_encoding`, reference BMP suite (largest).

## Acceptance

- Each codec: decode reference file -> compare pixels; re-encode -> decode
  byte-identical pixels (lossless formats).
- `clue test` module `tests/t_tier1.nim`.
