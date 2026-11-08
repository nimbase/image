# Converter: any format → WebP

`convert.nim` — the high-level API. Format is sniffed from magic bytes;
first frame wins for animated/multi-image inputs; 16-bit and float
sources auto-downconvert to 8-bit (never blank output).

```nim
import image

let any = decodeImage(bytes)                   # any format -> DynamicImage
let webp = convertToWebp(bytes, quality = 75)  # lossy (default)
let exact = convertToWebp(bytes, lossless = true)  # pixel-exact VP8L
let req = img.toWebp(90).crop(0, 0, 20, 20).encode()
let small = img.toWebp(75).lossless().encode()
```

## Procs (`convert.nim`)

- `decodeImage(data: seq[uint8]): ImageResult[DynamicImage]` (line 33) —
  dispatches on `guessFormat`. GIF composites frame 0 onto a full-canvas
  RGBA buffer; QOI/HDR/Farbfeld map to their native variant (`dkRgba8`,
  `dkRgb32F`, `dkRgba16`); AVIF routes to the stub and propagates its
  `ekUnsupported`. Empty input → `ekDecoding`; unknown magic →
  `ekUnsupported` (`ukFormat`).
- `normalizeToRgba8(img: DynamicImage): ImageResult[RgbaImage]` (line 88)
  — total over all 12 variants (unlike `toRgba8`).
- `toWebp(img, quality = 75): WebpRequest` (line 187) — fluent entry.
  Quality outside 1–100 is a recorded request error, surfaced by `encode()`.
- `WebpRequest.lossless(on = true)` / `.crop(x, y, w, h)` / `.encode()`
  (lines 195–243) — crop is strict (zero-size or out-of-bounds →
  `pkDimensionMismatch`), relative to the current request image, and only
  the first error is kept.
- `convertToWebp(data, quality = 75, lossless = false)` (line 245) —
  bytes-in entry: `decodeImage` → `toWebp(quality).lossless(lossless)`
  → `encode()`. Equivalent to the CLI's core.
- `WebpMaxDim = 16384` (line 30) — VP8L stores width-1/height-1 in
  14 bits; larger inputs fail with `lkDimensionError`.

## Downconvert math (exact, tested)

- 16-bit channels: `v div 257` — exact endpoints (0→0, 65535→255).
- float32: `clamp(v * 255 + 0.5)` per channel — HDR values outside
  `[0,1]` clamp; no tone mapping in v1.
- Alpha is preserved through both paths (`LumaA`, RGBA, 16-bit alpha).

## Quality/size guidance

- Lossy default is 75 (cwebp default); quality maps linearly to the VP8
  quantizer index. Measured on gradients: mean abs channel error grows as
  quality drops; lossy is smaller than lossless on smooth content.
- Lossless (VP8L with LZ77 + color cache; no transforms or meta-Huffman
  yet) is pixel-exact and decodes in any spec WebP decoder. Photos still
  compress modestly (a 24 MP photo ≈ 50 MB, vs ~61 MB literal-only):
  smooth gradients rarely repeat exactly, so most of the win is cache
  hits on flat areas. Flat/graphic content collapses dramatically
  (a flat 64×64 needs ~100 bytes). Prefer lossy for photos, lossless
  for exact round-trips.
