<p align="center">
  Pure-Nim image encoders and decoders, no C bindings.<br>
  Deflate via pure <a href="https://github.com/nimbase/archive">pkg/archive library</a>
</p>

<p align="center">
  <code>nimble install image</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/image/">API reference</a><br>
  <img src="https://github.com/nimbase/image/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/image/workflows/docs/badge.svg" alt="Github Actions">
</p>

> [!NOTE]
> This is an LLM-accelerated Nim package, a pure-Nim port of the Rust
> [`image`](https://github.com/image-rs/image) crate (v0.25.9), mirroring its
> API (`DynamicImage`, `ImageBuffer`, `ImageReader`, `ImageFormat`). Zero C
> bindings (deflate via pure-Nim `pkg/archive`); `imageops` processing
> functions are out of scope for v1, with one deliberate exception: a
> strict width/height crop (`cropImage`, no resampling) needed by the JPEG
> compression request builder.

> [!TIP]
> In-depth guides live in [docs/](docs/README.md).


## Features

- Colors: `ColorType`, `ExtendedColorType`, `Rgb`/`Rgba`/`Luma`/`LumaA` pixels, sRGB conversions
- Buffers: `ImageBuffer` (12 aliases), `DynamicImage` (12 variants), `FlatSamples`, `SubImage` views
- IO: `ImageFormat` (15 variants), magic-byte guessing, `Limits`, `ImageReader` helpers
- Errors: `ImageError` / `ImageResult[T]` with decoding, encoding, limits and unsupported kinds
- Converter: `decodeImage` (any format → `DynamicImage`), `normalizeToRgba8`, `convertToWebp` + fluent `toWebp().lossless().crop().encode()` — first frame wins for animated/multi-image, 16-bit/float auto-downconvert, max 16384px

Codec support (`o` = decode, `w` = encode):

- BMP: o+w — 1/4/8-bit palette, 16-bit bitfields, 24/32-bit, RLE4/RLE8
- EXR: o+w — scanline NONE/RLE/ZIP/ZIPS/PXR24, half/float/uint to 32F; PIZ/B44/DWAA/tiled/multipart unsupported
- Farbfeld: o+w — `Rgba16`
- GIF: o+w — animation, disposal, interlace, loop count, LZW
- HDR: o+w — Radiance RGBE, flat + new/old RLE
- ICO: o+w — PNG and BMP payloads, AND-mask transparency
- JPEG: o+w — baseline + progressive (SOF2) DCT decode, 4:4:4/4:2:0, quality 1–100; baseline encoder with optional optimized Huffman tables + fluent `compress().crop().encode()` API and strict `cropImage` (all 12 `DynamicImage` variants)
- PNG: o+w — all color types, 1/2/4/8/16-bit, all 5 filters, Adam7, tRNS
- PNM: o+w — P1–P6 plus PAM; writer emits P5/P6
- QOI: o+w — full op-index/run/diff/luma/rgb/rgba codec
- TGA: o+w — raw/RLE, colormaps, 15-bit, orientation
- TIFF: o+w — strips/tiles, chunky/planar, None/LZW/Deflate/PackBits, YCbCr/CMYK/palette
- WebP: o+w — lossless VP8L (LZ77 + color-cache encoder with predictor, subtract-green, per-block color and meta-Huffman transforms) + lossy VP8 keyframe decode (bit-exact vs dwebp, fancy upsampling) and encode (quality 1–100); animation / VP8X alpha unsupported
- AVIF: color math only (BT.601/709/2020 YCbCr, YCgCo-Re); AV1 bitstream unsupported
- HEIF/HEIC: o+w — ISOBMFF container + uncompressed (`unci` v0/v1, 8/16-bit) + JPEG-in-HEIF + `iden`/`grid`/`iovl` + `irot`/`imir`/`clap`/`iscl` + thumbnails/aux/groups/Exif/mime; HEVC/VVC/AVC/JPEG2000 passthrough only, sequences unsupported

Not ported (out of scope): `imageops` processing functions, rayon parallelism.

## Examples

All codecs return `ImageResult[T]` — check `.ok`, then use `.value`:

```nim
import image

let res = decodePng(bytes)
if res.ok:
  echo res.value.dimensions()
```

### BMP

```nim
let img = RgbImage(width: 2, height: 2, pixels: px)
let enc = encodeBmpRgb8(img)      # 24-bit BI_RGB
let dec = decodeBmp(enc)          # ImageResult[DynamicImage]
```

### EXR

```nim
let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(
  width: 2, height: 1, pixels: px))
let enc = encodeExr(img)          # ZIP scanlines
let dec = decodeExr(enc.value)    # Rgb32F back
```

### Farbfeld

```nim
let enc = encodeFarbfeld(img)     # Rgba16Image -> seq[uint8]
let dec = decodeFarbfeld(enc)     # ImageResult[Rgba16Image]
```

### GIF

```nim
let enc = encodeGif(@[frame0, frame1], 2, 2, palette, @[10'u16, 20'u16])
let gif = decodeGif(enc).value    # frames, delays, loop count
let rgba = gifFrameToRgba(gif, 0) # first frame as RgbaImage
```

### HDR

```nim
let enc = encodeHdr(img)          # Rgb32FImage -> Radiance RGBE
let dec = decodeHdr(enc.value)    # ImageResult[Rgb32FImage]
```

### ICO

```nim
let enc = encodeIco(@[img])       # PNG-compressed entries
let dec = decodeIco(enc.value)    # largest entry wins
```

### JPEG

```nim
let enc = encodeJpeg(img, 90)              # quality 1..100, 4:2:0 default
let enc2 = encodeJpeg(img, 95, subsample = false)  # 4:4:4
let enc3 = encodeJpeg(img, 75, optimize = true)    # smaller optimal Huffman tables
let dec = decodeJpeg(enc.value)   # baseline DCT
let req = img.compress(50).crop(300, 300, 20, 20).encode()  # fluent: strict crop + encode
let opt = img.compress(90).subsampled(false).optimized().encode()
let c = cropImage(img, 0, 0, 20, 20)  # strict, variant-preserving; 8-bit inputs only for JPEG
```

### PNG

```nim
let img = DynamicImage(kind: dkRgb8, rgb8: rgb)
let enc = encodePng(img)          # filter None + deflate
let dec = decodePng(enc.value)    # validates CRC, unfilters, deinterlaces
```

### PNM

```nim
let enc = encodePnmRgb8(img)      # P6 binary
let enc2 = encodePnmGray8(gray)   # P5 binary
let dec = decodePnm(enc)          # P1-P7 -> DynamicImage
```

### QOI

```nim
let enc = encodeQoi(img)          # RgbaImage, auto channels
let dec = decodeQoi(enc)          # ImageResult[RgbaImage]
```

### TGA

```nim
let enc = encodeTgaRgb8(img)      # uncompressed, top-left origin
let enc2 = encodeTgaRgba8(rgba)
let dec = decodeTga(enc)          # handles RLE, colormaps, orientation
```

### TIFF

```nim
let enc = encodeTiff(img)         # little-endian, single strip
let dec = decodeTiff(enc.value)   # first page -> DynamicImage
let pages = decodeTiffAll(bytes)  # multi-page -> seq[DynamicImage]
```

### WebP

```nim
let enc = encodeWebp(img)         # lossless VP8L
let dec = decodeWebp(enc.value)   # opaque -> Rgb8, alpha -> Rgba8
```

### Converter (any format → WebP)

```nim
let any = decodeImage(bytes)      # magic-byte sniffed, first frame wins
let webp = convertToWebp(bytes, quality = 75)      # lossy (default)
let exact = convertToWebp(bytes, lossless = true)  # pixel-exact VP8L
let req = img.toWebp(90).crop(0, 0, 20, 20).encode()  # fluent + strict crop
let small = img.toWebp(75).lossless().encode()
```

16-bit maps exactly (`v div 257`), float clamps `[0,1]` (no tone mapping
in v1). CLI: `examples/webp_convert` (`webp_convert input output
[--quality N] [--lossless]`).

### AVIF

```nim
let (y, u, v) = rgbToYuvPixel(255, 0, 0, ymBT709, yrFull)
let (r, g, b) = yuvToRgbPixel(y, u, v, ymBT709, yrFull)
let (yy, cg, co) = ycgcoReForward(255, 0, 0)   # lossless round-trip pair
let (r2, g2, b2) = ycgcoReInverse(yy, cg, co)
let img = yuv420ToRgb(yPlane, uPlane, vPlane, w, h, ymBT601, yrFull)
```

### HEIF/HEIC

```nim
let dec = decodeHeif(bytes)   # primary still -> DynamicImage
let dec2 = decodeHeic(bytes)  # alias (HEIC = HEVC-branded HEIF)
let raw = extractJ2kCodestream(bytes)  # raw codestream for external decoders
let enc = encodeHeif(img).value          # uncompressed still
let encJ = encodeHeifJpeg(img, 90).value # JPEG-in-HEIF
let coll = writeCollection(myCollection).value # thumbs/aux/grid/iovl/groups
```

### Format detection

```nim
let (found, fmt) = guessFormat(bytes)  # magic-byte sniffing
let f = fromExtension("png")           # (found, fmtPng)
let m = fromMimeType("image/jpeg")     # (found, fmtJpeg)
```

## Roadmap

- [x] Core: colors, buffers, `DynamicImage`, format detection, limits, errors
- [x] Shared: `archive` library inflate/deflate/CRC32, pure-Nim LZW (GIF/TIFF)
- [x] BMP (palette, bitfields, RLE4/RLE8)
- [x] EXR scanline subset (NONE/RLE/ZIP/ZIPS, half/float/uint)
- [x] Farbfeld
- [x] GIF (animation, interlace, loop count)
- [x] HDR (flat + new/old RLE)
- [x] ICO (PNG + BMP payloads, AND mask)
- [x] JPEG baseline (DCT, 4:4:4/4:2:2/4:2:0, encoder with quality 1–100, optimized Huffman, fluent compress/crop API)
- [x] PNG (all color types, filters, Adam7, tRNS, CRC)
- [x] PNM (P1–P6 + PAM)
- [x] QOI (full opcode set)
- [x] TGA (raw/RLE, colormaps, orientation)
- [x] TIFF (strips/tiles, 4 compressions, YCbCr/CMYK/palette)
- [x] WebP lossless VP8L (LZ77 + predictor/sub-green/color/meta-Huffman; validated vs dwebp — still open: palette transform, LZ77 parse quality vs cwebp on photos, adaptive block sizes, cache tuning)
- [x] AVIF color math (BT.601/709/2020 YCbCr, YCgCo-Re)
- [x] JPEG progressive (SOF2) decode (spectral selection + successive approximation; encoder stays baseline-only)
- [x] WebP lossy VP8 keyframe decode (bit-exact vs dwebp)
- [ ] EXR PIZ/PXR24/B44/DWAA + tiled/multipart
- [ ] AVIF bitstream (requires an AV1 decoder)
- [x] HEIF/HEIC stills: container + uncompressed + JPEG-in-HEIF + grids/overlays/iden + thumbnails/aux/groups/Exif/mime + writer (HEVC/VVC/AVC/JPEG2000 passthrough only — no pure-Nim video/wavelet decoders)
- [ ] JPEG XL (jxl)
- [ ] JPEG 2000 (jp2)
- [ ] HEIF sequences/timed tracks, tiled `iloc` construction-2, EVC brand
- [ ] RAW (a family of formats, not one codec; often requires camera-specific metadata and processing)
- [x] SIMD: PNG Up filter, JPEG IDCT/FDCT, YCbCr row batch via nimsimd (runtime auto-dispatch SSE2/AVX2/NEON, bit-identical scalar fallback; `-ffp-contract=off`)
- [ ] SIMD: PNG Average/Paeth/Sub (scalar by design — small rows stay scalar)
- [ ] `imageops` processing functions (blur, resize, rotate — excluded from v1)

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/image/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/image/fork)

### 🎩 License
MIT license | Nim Community.
