<p align="center">
  Pure-Nim image encoders and decoders<br>
  <i>A Nim port of <code>image-rs/image</code>. No C bindings — only <code>pkg/zlib</code> for deflate.</i><br>
</p>

<p align="center">
  <code>nimble install image</code>
</p>

<p align="center">
  <a href="https://nimbase.github.io/{nimbase-repo-name}/">API reference</a><br>
  <img src="https://github.com/nimbase/{nimbase-repo-name}/workflows/test/badge.svg" alt="Github Actions">  <img src="https://github.com/nimbase/{nimbase-repo-name}/workflows/docs/badge.svg" alt="Github Actions">
</p>


## Features

Core types mirroring `image-rs/image`:

- Colors: `ColorType`, `ExtendedColorType`, `Rgb`/`Rgba`/`Luma`/`LumaA` pixels, sRGB conversions
- Buffers: `ImageBuffer` (12 aliases), `DynamicImage` (12 variants), `FlatSamples`, `SubImage` views
- IO: `ImageFormat` (14 variants), magic-byte guessing, `Limits`, `ImageReader` helpers
- Errors: `ImageError` / `ImageResult[T]` with decoding, encoding, limits and unsupported kinds

Codec support (`o` = decode, `w` = encode):

- BMP: o+w — 1/4/8-bit palette, 16-bit bitfields, 24/32-bit, RLE4/RLE8
- EXR: o+w — scanline NONE/RLE/ZIP/ZIPS, half/float/uint to 32F; PIZ/tiled/multipart unsupported
- Farbfeld: o+w — `Rgba16`
- GIF: o+w — animation, disposal, interlace, loop count, LZW
- HDR: o+w — Radiance RGBE, flat + new/old RLE
- ICO: o+w — PNG and BMP payloads, AND-mask transparency
- JPEG: o+w — baseline DCT, 4:4:4/4:2:0, quality 1–100; progressive unsupported
- PNG: o+w — all color types, 1/2/4/8/16-bit, all 5 filters, Adam7, tRNS
- PNM: o+w — P1–P6 plus PAM; writer emits P5/P6
- QOI: o+w — full op-index/run/diff/luma/rgb/rgba codec
- TGA: o+w — raw/RLE, colormaps, 15-bit, orientation
- TIFF: o+w — strips/tiles, chunky/planar, None/LZW/Deflate/PackBits, YCbCr/CMYK/palette
- WebP: o+w — lossless VP8L decode (meta-Huffman, LZ77, all transforms) + literal-only encoder; lossy VP8 unsupported
- AVIF: color math only (BT.601/709/2020 YCbCr, YCgCo-Re); AV1 bitstream unsupported

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
let dec = decodeJpeg(enc.value)   # baseline DCT
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

### AVIF

```nim
let (y, u, v) = rgbToYuvPixel(255, 0, 0, ymBT709, yrFull)
let (r, g, b) = yuvToRgbPixel(y, u, v, ymBT709, yrFull)
let (yy, cg, co) = ycgcoReForward(255, 0, 0)   # lossless round-trip pair
let (r2, g2, b2) = ycgcoReInverse(yy, cg, co)
let img = yuv420ToRgb(yPlane, uPlane, vPlane, w, h, ymBT601, yrFull)
```

### Format detection

```nim
let (found, fmt) = guessFormat(bytes)  # magic-byte sniffing
let f = fromExtension("png")           # (found, fmtPng)
let m = fromMimeType("image/jpeg")     # (found, fmtJpeg)
```

### ❤ Contributions & Support
- 🐛 Found a bug? [Create a new Issue](https://github.com/nimbase/{nimbase-repo-name}/issues)
- 👋 Wanna help? [Fork it!](https://github.com/nimbase/{nimbase-repo-name}/fork)

### 🎩 License
MIT license | Nim Community.
