# 01 — Core Foundation (do first)

Sources: `src/color.rs:1134`, `src/error.rs:604`, `src/traits.rs:590`,
`src/images/buffer.rs:2703`, `src/images/dynimage.rs:2540`,
`src/images/generic_image.rs:587`, `src/images/sub_image.rs:300`,
`src/images/flat.rs:2118`, `src/io.rs:149`, `src/io/decoder.rs:356`,
`src/io/encoder.rs:152`, `src/io/format.rs:431`, `src/io/limits.rs:178`,
`src/io/free_functions.rs`, `src/io/image_reader_type.rs:1123`, `src/lib.rs:120-294`.

## 1.1 `color.nim`

Port `ColorType` (12 variants L8..Rgba32F) + methods:
`bytesPerPixel`, `hasAlpha`, `hasColor`, `bitsPerPixel`, `channelCount`.
Port `ExtendedColorType` (all incl. A8/L1..Rgba4/Rgb5x1/Bgr8/Bgra8/Cmyk8/16/YCbCr8/Unknown).
`channelCount`, `bitsPerPixel`, `colorType() Option`, `bufferSize(w,h): uint64`.
Pixels: `Rgb[T]`, `Rgba[T]`, `Luma[T]`, `LumaA[T]` as `object` with `array[N,T]`.
`FromPrimitive` rules (u8<->u16 scale 257, u8->u16 `(x shl 8)|x`, f32 bias 0.5 + NaN->1.0).
`FromColor` full 4x4 matrix, `rgbToLuma` from `primitive_sealed.rs:231`.
`Blend` (src-over for Rgba/LumaA), `Invert`.

Nim notes: use generics `Rgb[T: SomeNumber]`, concepts for `Primitive`.
`f32` color range 0.0..1.0, `DEFAULT_MAX_VALUE` const per type.

## 1.2 `error.nim`

```nim
type ImageError* = object
  case kind*: ImageErrorKind
  of Decoding, Encoding, Parameter, Limits, Unsupported, IoError: ...
```

Port `UnsupportedErrorKind`, `ParameterErrorKind`, `LimitErrorKind`,
`ImageFormatHint` (Exact/Name/PathExtension/Unknown).
`ImageResult[T] = Result[T, ImageError]` (use `std/results` or custom).
`Display` messages must match Rust strings for test compat.

## 1.3 `traits.nim` + `generic.nim`

- `Primitive` concept: `copy + Num + Bounded`, `DEFAULT_MAX_VALUE/MIN_VALUE`.
- `Enlargeable` (u8->u32, u16->u32, f32->f64 etc.), `Lerp`.
- `Pixel` concept: `CHANNEL_COUNT`, `channels`, `toRgb/toRgba/toLuma/toLumaA`,
  `apply/applyWithAlpha/map2/invert/blend`.
- `PixelWithColorType`: `COLOR_TYPE: ExtendedColorType` const.
- `GenericImageView/GenericImage`: `dimensions`, `getPixel/putPixel`,
  `view/subImage`, `pixels/rows/enumeratePixels` iterators.

## 1.4 `buffer.nim` + `dynamic.nim`

`ImageBuffer[P, Container = seq[T]]`:
`width/height`, `fromRaw/intoRaw/asRaw`, `subpixels/pixels/rows/enumerate*`,
`getPixel/putPixel (+checked)`, `cropInPlace`, `setAlphaChannel`,
`save/saveWithFormat/writeTo/writeWithEncoder`, `new`, `fromFn`.
Aliases: `GrayImage, GrayAlphaImage, RgbImage, RgbaImage, Gray16Image...,
Rgb32FImage...` (12 total matching `lib.rs:130-140`).

`DynamicImage`: variant object with 12 cases
`ImageLuma8..ImageRgba32F` (see `dynimage.rs:73-108`).
Port `color()`, `dimensions`, `toLuma8/toRgb8/...`, `save/writeTo`,
`fromDecoder`, `loadFromMemory`, `open`, `writeBufferWithFormat`.
`dynimage_conversion_8bit` helper for encoders.

## 1.5 `format.nim` + `reader.nim` + `limits.nim` + `decoder.nim`/`encoder.nim`

- `ImageFormat`: 14 variants. `fromExtension` (jpg/jpeg/jfif, png/apng, gif,
  webp, tif/tiff, tga, bmp, ico, hdr, exr, pbm/pam/ppm/pgm/pnm, ff, qoi, avif),
  `fromPath`, `fromMimeType/toMimeType`, `extensionsStr`, `all()`.
  Skip `reading_enabled/writing_enabled` cfg-flags; always true, or gate by
  compile define.
- `Limits`: `maxImageWidth/Height: Option[uint32]`, `maxAlloc: Option[uint64]`
  default 512MiB. `checkDimensions`, `reserve/reserveUsize/reserveBuffer`,
  `free/freeUsize`, `checkSupport`, `noLimits()`.
- `ImageDecoder` concept: `setLimits`, `formatAttributes`,
  `animationAttributes`, `prepareImage -> DecoderPreparedImage`,
  `readImage(buf: var openArray[uint8])`, `icc/exif/xmp/iptc`,
  `moreImages`, `finish`. Protocol order: configure -> prepare -> read -> finish.
- `ImageEncoder` concept: `writeImage(buf, w, h, color)`,
  `setIccProfile/setExif/setXmp` (default Unsupported).
- `ImageReader`: wraps `Stream` (Nim `streams`), `withGuessedFormat`,
  `setFormat`, `decode`, `intoFrames`. Magic sniffing in `freefuncs.guessFormat`.
- `ImageLayout(w,h,color)`, `totalBytes: uint64`, overflow -> `u64.MAX` path
  must error like `decoder.rs:335 total_bytes_overflow` test.

## Acceptance

- `clue build src/image.nim` green.
- Unit tests: color conversions (lossless u8->u16->u8), blend/invert,
  format fromPath table, limits reserve/overflow, buffer put/get.
