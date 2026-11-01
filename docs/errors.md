# Errors

`error.nim` mirrors the upstream error model. Every public codec and
converter proc returns `ImageResult[T]` — a boolean-tagged object holding
either `value: T` or `err: ImageError`. Decode/encode never raises on bad
input; only `unwrap` raises (for tests and scripts).

```nim
let res = decodePng(bytes)
if not res.ok:
  echo res.err.kind  # ekDecoding
  echo res.err.msg
else:
  echo res.value.dimensions()
```

## Kinds (`ImageErrorKind`)

| Kind | Meaning | Constructors |
|---|---|---|
| `ekDecoding` | input is corrupt/truncated | `decodingError(msg)` |
| `ekEncoding` | cannot encode (empty, too large) | `encodingError(msg)` |
| `ekParameter` | bad caller argument, refined by `ParamKind` | `paramError(k, msg)` |
| `ekLimits` | over `Limits`, refined by `LimitKind` | `limitError(k, msg)` |
| `ekUnsupported` | valid input, unsupported feature, refined by `UnsupportedKind` | `unsupportedError(k, msg)` |
| `ekIo` | transport failure (caller's reader) | `ioError(msg)` |

`ParamKind`: `pkDimensionMismatch`, `pkFailedAlready`, `pkNoMoreData`,
`pkBufferSizeMismatch`, `pkNoAlphaChannel`, `pkGeneric`.
`LimitKind`: `lkDimensionError`, `lkInsufficientMemory`, `lkUnsupported`.
`UnsupportedKind`: `ukColor`, `ukColorLayout`, `ukFormat`, `ukGenericFeature`.

## Conventions

- Unknown magic bytes → `ekUnsupported` (`convert: unknown image format`),
  empty input → `ekDecoding` (`convert: empty input`).
- Partially supported inputs (EXR PIZ, HEIF video/J2K, animated WebP)
  return the decoder's clean `ekUnsupported`, never a half-decoded image.
- Fluent builders (`compress().crop().encode()`, `toWebp().crop().encode()`)
  record the *first* error and surface it from `encode()`.
