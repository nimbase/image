# Codecs

`o` = decode, `w` = encode. Signatures are the contract: `seq[uint8]`
codecs take/return bytes, typed codecs take/return pixel buffers.
`ImageResult[seq[uint8]]` encoders vs plain-`seq[uint8]` encoders differ —
check the return type before calling `.value`.

| Codec | Support | Decode proc | Encode proc |
|---|---|---|---|
| BMP | o+w: 1/4/8-bit palette, 16-bit bitfields, 24/32-bit, RLE4/RLE8 | `decodeBmp` → `DynamicImage` | `encodeBmpRgb8`, `encodeBmpRgba8` → `seq[uint8]` |
| EXR | o+w: scanline NONE/RLE/ZIP/ZIPS, half/float/uint → 32F. No PIZ/tiled/multipart | `decodeExr` / `decodeExrAll` | `encodeExr` → `ImageResult` |
| Farbfeld | o+w: `Rgba16` | `decodeFarbfeld` → `Rgba16Image` | `encodeFarbfeld` → `seq[uint8]` |
| GIF | o+w: animation, disposal, interlace, loop count, LZW | `decodeGif` → `GifImage` (frames + delays) | `encodeGif(frames, w, h, …)` |
| HDR | o+w: Radiance RGBE, flat + new/old RLE | `decodeHdr` → `Rgb32FImage` | `encodeHdr` / `encodeHdrFlat` → `seq[uint8]` |
| ICO | o+w: PNG and BMP payloads, AND-mask; largest entry wins | `decodeIco` / `decodeIcoAll` | `encodeIco` → `ImageResult` |
| JPEG | o: baseline + progressive (SOF2), 4:4:4/4:2:0, optional downscale. w: baseline, quality 1–100, 4:2:0 default, optimal Huffman + fluent `compress().crop().encode()` | `decodeJpeg(data, denom = 1)` | `encodeJpeg(img, quality, …)` → `ImageResult` |
| PNG | o+w: all color types, 1/2/4/8/16-bit, all 5 filters, Adam7, tRNS, CRC | `decodePng` → `DynamicImage` | `encodePng` → `ImageResult` |
| PNM | o+w: P1–P6 plus PAM; writer emits P5/P6 | `decodePnm` → `DynamicImage` | `encodePnmGray8`, `encodePnmRgb8` → `seq[uint8]` |
| QOI | o+w: full op-index/run/diff/luma/rgb/rgba | `decodeQoi` → `RgbaImage` | `encodeQoi` → `seq[uint8]` |
| TGA | o+w: raw/RLE, colormaps, 15-bit, orientation | `decodeTga` → `DynamicImage` | `encodeTgaRgb8`, `encodeTgaRgba8` → `seq[uint8]` |
| TIFF | o+w: strips/tiles, chunky/planar, None/LZW/Deflate/PackBits, YCbCr/CMYK/palette. First page by default | `decodeTiff` / `decodeTiffAll` | `encodeTiff` → `ImageResult` |
| WebP | o+w: lossless VP8L (literal-only encoder) + lossy VP8 keyframe decode (bit-exact vs dwebp, fancy upsampling) and encode (quality 1–100). No animation / VP8X alpha | `decodeWebp` → `DynamicImage` | `encodeWebp` (lossless, `ImageResult`), `encodeWebpLossy(RgbaImage, quality)` (raw VP8 frame → RIFF) |
| AVIF | color math only: BT.601/709/2020 YCbCr, YCgCo-Re, yuv420→rgb. No AV1 bitstream | `decodeAvif` (v1 stub → `ekUnsupported`) | `encodeAvif` (stub) |
| HEIF/HEIC | o (decode-only): ISOBMFF + uncompressed (`unci` v0/v1) + JPEG-in-HEIF + `irot`/`imir`/`clap`/`iden`. No HEVC/VVC/AVC/JPEG2000 bitstreams, grids, overlays, sequences | `decodeHeif` / `decodeHeic` → `DynamicImage` | — (none) |

## Quirks worth knowing

- JPEG `encodeJpeg(img, quality, subsample = true, optimize = false)`:
  4:2:0 by default, `subsample = false` for 4:4:4, `optimize = true` for
  smaller optimal Huffman tables. `decodeJpeg(data, denom)` downscales by
  powers of two at decode time.
- TIFF writer emits little-endian single-strip; decoder handles both orders.
- ICO decode picks the largest entry; `decodeIcoAll` returns all.
- `decodeAvif` / `encodeAvif` exist so `decodeImage` can route AVIF magics,
  but both return `ekUnsupported` in v1 (color math helpers like
  `rgbToYuvPixel`, `yuv420ToRgb`, `ycgcoReForward/Inverse` are usable).
- WebP lossy encode is VP8 intra-only keyframes, single partition, default
  token probabilities (no RDO/adaptation): ~1.5–1.8× cwebp size at high Q.
- GIF decode gives `GifImage`; use `gifFrameToRgba(gif, 0)` for frame 0.
  The converter composites frame 0 onto a full-canvas buffer.
