# Core types

## Pixels (`color.nim`)

Generic pixel types over the channel type: `Rgb[T]`, `Rgba[T]`,
`Luma[T]`, `LumaA[T]` with `data: array[N, T]`. `ColorType` enumerates the
8-bit/16-bit/float layouts; `ExtendedColorType` covers the CMYK/YUV
special cases. sRGB conversion helpers live here too.

## Buffers (`buffer.nim`)

`ImageBuffer[P]` is a width/height/pixels container. Twelve named aliases
cover every channel-depth combination:

| Alias | Pixel |
|---|---|
| `GrayImage` / `GrayAlphaImage` | `Luma[uint8]` / `LumaA[uint8]` |
| `RgbImage` / `RgbaImage` | `Rgb[uint8]` / `Rgba[uint8]` |
| `Gray16Image` / `GrayAlpha16Image` | `Luma[uint16]` / `LumaA[uint16]` |
| `Rgb16Image` / `Rgba16Image` | `Rgb[uint16]` / `Rgba[uint16]` |
| `Gray32FImage` / `GrayAlpha32FImage` | `Luma[float32]` / `LumaA[float32]` |
| `Rgb32FImage` / `Rgba32FImage` | `Rgb[float32]` / `Rgba[float32]` |

`FlatSamples` (flat byte view) and `SubImage` (borrowed window) views are
also defined here.

## DynamicImage (`dynamic.nim`)

The canonical decoded value — a 12-variant object (`dkLuma8` …
`dkRgba32F`, one per alias above):

```nim
let img = DynamicImage(kind: dkRgb8, rgb8: rgb)
echo img.dimensions()  # (w, h) tuple, works for every variant
```

- `dimensions()` works on all variants.
- `cropImage(img, x, y, w, h)` is strict and variant-preserving (all 12
  variants): out-of-bounds or zero-size crops return an error, never a
  clipped image. 8-bit inputs only for the JPEG path.
- `toRgba8` converts where defined, but does not cover every variant —
  the converter's `normalizeToRgba8` does (see [converter](converter.md)).

## Animation / metadata

- `animation.nim`: `Frame` (position, size, `Delay`, raw bytes),
  `Delay` (`numer`/`denom`, `delayMs`/`toMs`), `LoopCount`
  (`infiniteLoop`/`finiteLoop`). Framing only, no compositing except the
  converter's GIF frame-0 path.
- `metadata.nim`: `Orientation`, EXIF/IPTC/XMP hooks; per-format attribute
  reporting lives in `decoder.nim` (`FormatAttributes`,
  `DecodedImageAttributes`).
