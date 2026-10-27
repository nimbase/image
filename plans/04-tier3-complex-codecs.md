# 04 — Tier 3 Complex Codecs (jpeg, webp, openexr, avif)

All start as `Unsupported` stubs, then land one by one.
No processing-functions dependency; only core buffer + zlib/lzw helpers.

## 4.1 JPEG (`codecs/jpeg/: decoder 262, encoder 496` + externals)

Reference clones (see `05-external-crates.md`):
- `references/zune-jpeg` (`zune-jpeg@0.5.15`, decode: markers, Huffman, DCT/IDCT, upsampling)
- `references/zune-core` (`zune-core@0.5.0`: colorspace, options)
- `references/jpeg-encoder` (`jpeg-encoder@0.7.0`, encode: DCT, quantization tables)

Port order:
1. Baseline DCT sequential, 8-bit, 1/3 components (Luma/RGB/YCbCr), Huffman DC/AC,
   restart markers, JFIF/Adobe headers. Output Rgb8/L8. DONE.
2. Progressive SOF2 (spectral selection + successive approximation). DONE —
   decoder only; single-component scans visit blocks in raster order, encoder
   stays baseline-only.
3. 12-bit / arithmetic / lossless -> `Unsupported` first pass.
4. Encoder: quality tables, subsampling 4:4:4/4:2:2/4:2:0, JFIF header.
   Match `save_jpeg.rs` test behavior. DONE (baseline-only).

Nim notes: IDCT must be bit-exact-ish (LLM integer path from zune-jpeg).
Huffman decoder table-driven, not tree-walk, for speed.

## 4.2 WebP (`codecs/webp/: decoder, encoder, mod` + `image-webp@0.2.0`)

Reference clone: `references/image-webp` (pinned v0.2.4; Cargo range
`0.2.0` resolves to it).
- Lossless VP8L first (simpler, Huffman + LZ77 + color cache, like PNG-adjacent).
  DONE (`vp8l.nim` + container in the same file).
- Lossy VP8 keyframe decode. DONE (`vp8.nim`: bool decoder, segmentation,
  quant, token probs, 4x4 WHT/IDCT, intra prediction, loop filter, fancy
  YUV upsampling). Validated bit-exact vs `dwebp` on 100x100 color/gray,
  101x57 odd-size and 640x427 segmented photo fixtures
  (`tests/fixtures/webp/lossy_images/`). Still `Unsupported`: VP8X+ALPH
  compositing, animation (`ANIM`/`ANMF`), interframes (stills never have them).
- Encoder: lossless only (matches Rust note "only lossless encoding
  currently supported"), lossy later.

## 4.3 OpenEXR (`codecs/openexr.rs:560` + `exr@1.74.0`)

Reference clone: `references/exrs` (johannesvollmer/exrs).
- Header (magic, version, channels, compression, dataWindow), scanline + tiled,
  half-float (port `f16` conv pure Nim), compression: NONE/RLE/ZIP/ZIPS/PIZ
  first; PXR24/B44/DWAA/DWAB -> `Unsupported` first pass.
- Output Rgb32F/Rgba32F. No deep/shadow maps initially.

## 4.4 AVIF (`codecs/avif/: decoder 815, encoder, yuv 1277, ycgco 410` + `ravif@0.13`)

Reference clone: `references/ravif` (+ `rgb@0.8.48` types).
- Port `yuv.rs` (BT.601/709/2020, limited/full range, 8/10/12-bit, 4:2:0/4:2:2/4:4:4)
  and `ycgco.rs` first — these are pure color math, reusable by JPEG/TIFF YCbCr too.
- AV1 payload: requires rav1e/dav1d (C). Pure-Nim AV1 decode is out of scope
  for v1 — decoder returns `Unsupported(Format(Avif))` with clear message,
  encoder likewise. Ship YUV helpers + container parse (mp4 boxes) so a future
  pure-Nim AV1 can plug in.

## Acceptance per codec

- JPEG: `tests/images/jpg/**` incl. progressive `cat.jpg` from README.
- WebP: lossless round-trip; lossy decode reference suite.
- EXR: scanline ZIP/NONE round-trip, half-float edge values.
- AVIF: yuv/ycgco unit vectors pass; avif files give clean `Unsupported`, not panic.
