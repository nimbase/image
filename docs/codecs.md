# Codecs

`o` = decode, `w` = encode. Signatures are the contract: `seq[uint8]`
codecs take/return bytes, typed codecs take/return pixel buffers.
`ImageResult[seq[uint8]]` encoders vs plain-`seq[uint8]` encoders differ —
check the return type before calling `.value`.

| Codec | Support | Decode proc | Encode proc |
|---|---|---|---|
| BMP | o+w: 1/4/8-bit palette, 16-bit bitfields, 24/32-bit, RLE4/RLE8 | `decodeBmp` → `DynamicImage` | `encodeBmpRgb8`, `encodeBmpRgba8` → `seq[uint8]` |
| EXR | o+w: scanline NONE/RLE/ZIP/ZIPS/PXR24/B44/B44A/PIZ/DWAA/DWAB, half/float/uint → 32F. No tiled/multipart | `decodeExr` / `decodeExrAll` | `encodeExr` (`compression = 3` ZIP default, `4` PIZ, `5` PXR24, `6`/`7` B44/B44A, `8`/`9` DWAA/DWAB at default level 45) → `ImageResult` |
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
| WebP | o+w: lossless VP8L (LZ77 + color-cache encoder with predictor, subtract-green, per-block color and meta-Huffman transforms; no color-index yet) + lossy VP8 keyframe decode (bit-exact vs dwebp, fancy upsampling) and encode (quality 1–100). No animation / VP8X alpha | `decodeWebp` → `DynamicImage` | `encodeWebp` (lossless, `ImageResult`), `encodeWebpLossy(RgbaImage, quality)` (raw VP8 frame → RIFF) |
| AVIF | color math only: BT.601/709/2020 YCbCr, YCgCo-Re, yuv420→rgb. No AV1 bitstream | `decodeAvif` (v1 stub → `ekUnsupported`) | `encodeAvif` (stub) |
| HEIF/HEIC | o+w: ISOBMFF container + uncompressed (`unci` v0/v1, incl. tiled tile-component "TL" profile) + JPEG-in-HEIF + `iden`/`grid`/`iovl` (all 8/16-bit mono/colour kinds) + `irot`/`imir`/`clap`/`iscl` + thumbnails/aux/entity-groups/Exif/mime + tiled `iloc` construction-1 (`idat`) / construction-2 (item offsets) + timed `pict` sequences (`unci` v0/v1 / `jpeg`, incl. fragmented `moof`) + EVC brand passthrough. No HEVC/VVC/AVC/EVC/JPEG2000 bitstream decode (passthrough via extractors) | `decodeHeif` / `decodeHeic` / `decodeHeifAll` / `decodeHeifItem` / `decodeHeifSequenceAll` / `decodeHeifSequenceSample` → `DynamicImage`, `heifMetadata`, `heifGroups`, `heifMovieInfo` | `encodeHeif`, `encodeHeifJpeg`, `writeCollection` (`HeifCollection`), `writeHeifSequence` |

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
- WebP lossy encode is VP8 intra-only keyframes, single partition, RDO
  mode search over fully-quantized candidates + trellis-refined levels
  + two-pass adaptive token probabilities.
- WebP lossless encoder memory is tunable at compile time without touching
  defaults: `-d:Vp8lHashBits=N` (10..22, default 18; LZ77 hash table holds
  1 shl N ints) and `-d:Vp8lCacheBits=N` (1..11, default 7; color cache
  holds 1 shl N entries). Defaults are the reference operating point and
  produce the reference bytes; overrides stay spec-valid but may change
  output bytes and compression.
- GIF decode gives `GifImage`; use `gifFrameToRgba(gif, 0)` for frame 0.
  The converter composites frame 0 onto a full-canvas buffer.
