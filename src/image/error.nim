## Error types mirroring references/image/src/error.rs
import ./color

type
  ImageErrorKind* = enum
    ekDecoding
    ekEncoding
    ekParameter
    ekLimits
    ekUnsupported
    ekIo

  ParamKind* = enum
    pkDimensionMismatch
    pkFailedAlready
    pkNoMoreData
    pkBufferSizeMismatch
    pkNoAlphaChannel
    pkGeneric

  LimitKind* = enum
    lkDimensionError
    lkInsufficientMemory
    lkUnsupported

  UnsupportedKind* = enum
    ukColor
    ukColorLayout
    ukFormat
    ukGenericFeature

  FormatHintKind* = enum
    fhExact
    fhName
    fhPathExtension
    fhUnknown

  ImageError* = object
    kind*: ImageErrorKind
    msg*: string
    paramKind*: ParamKind
    limitKind*: LimitKind
    unsupportedKind*: UnsupportedKind
    color*: ExtendedColorType
    hint*: string

  ImageResult*[T] = object
    case ok*: bool
    of true:
      value*: T
    of false:
      err*: ImageError

func ok*[T](v: T): ImageResult[T] =
  ImageResult[T](ok: true, value: v)

func err*[T](e: ImageError): ImageResult[T] =
  ImageResult[T](ok: false, err: e)

func decodingError*(msg: string): ImageError =
  ImageError(kind: ekDecoding, msg: msg)

func encodingError*(msg: string): ImageError =
  ImageError(kind: ekEncoding, msg: msg)

func paramError*(k: ParamKind, msg = ""): ImageError =
  ImageError(kind: ekParameter, paramKind: k, msg: msg)

func limitError*(k: LimitKind, msg = ""): ImageError =
  ImageError(kind: ekLimits, limitKind: k, msg: msg)

func unsupportedError*(k: UnsupportedKind, msg = ""): ImageError =
  ImageError(kind: ekUnsupported, unsupportedKind: k, msg: msg)

func ioError*(msg: string): ImageError =
  ImageError(kind: ekIo, msg: msg)

func isOk*[T](r: ImageResult[T]): bool = r.ok

func unwrap*[T](r: ImageResult[T]): T =
  if not r.ok:
    raise newException(CatchableError, r.err.msg)
  r.value
