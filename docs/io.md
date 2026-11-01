# IO: format detection, limits

## Format detection

`ImageFormat` (`format.nim`) has 15 variants: `fmtPng`, `fmtJpeg`,
`fmtGif`, `fmtWebP`, `fmtPnm`, `fmtTiff`, `fmtTga`, `fmtBmp`, `fmtIco`,
`fmtHdr`, `fmtOpenExr`, `fmtFarbfeld`, `fmtAvif`, `fmtQoi`, `fmtHeif`.

```nim
let (found, fmt) = guessFormat(bytes)  # reader.nim, magic bytes, never raises
let f = fromExtension("png")           # format.nim, (found, fmtPng)
let m = fromMimeType("image/jpeg")     # format.nim, (found, fmtJpeg)
```

- `guessFormat` sniffs magic bytes (returns `(false, _)` when unknown).
  The converter extends it beyond the obvious magics: TIFF (II/MM),
  ICO, PNM (`P1`–`P6`), bare TGA headers, OpenEXR (`76 2F 31 01`).
- `decodeImage` dispatches on `guessFormat` — see [converter](converter.md).

## Limits (`limits.nim`)

```nim
var lim = defaultLimits()  # 512 MiB alloc cap, no dimension caps
var free = noLimits()
checkDimensions(lim, w, h)          # ImageResult[bool]
reserveBuffer(lim, w, h, colorType) # reserves w*h*bytesPerPixel
```

- Defaults mirror the upstream crate: bounded allocation, unbounded
  dimensions unless the caller sets them.
- Decoders report `ekLimits` (`lkDimensionError` / `lkInsufficientMemory`)
  instead of allocating blindly. The converter additionally caps WebP
  output at 16384px per side (VP8L header limit, `WebpMaxDim`).
