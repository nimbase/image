## Color types mirroring references/image/src/color.rs
## ColorType (12 variants), ExtendedColorType, Rgb/Rgba/Luma/LumaA pixels.

type
  ColorType* = enum
    ctL8
    ctLa8
    ctRgb8
    ctRgba8
    ctL16
    ctLa16
    ctRgb16
    ctRgba16
    ctL32F
    ctLa32F
    ctRgb32F
    ctRgba32F

  ExtKind* = enum
    ekA8
    ekL1, ekLa1, ekRgb1, ekRgba1
    ekL2, ekLa2, ekRgb2, ekRgba2
    ekL4, ekLa4, ekRgb4, ekRgba4
    ekRgb5x1
    ekL8, ekLa8, ekRgb8, ekRgba8
    ekL16, ekLa16, ekRgb16, ekRgba16
    ekBgr8, ekBgra8
    ekL32F, ekLa32F, ekRgb32F, ekRgba32F
    ekCmyk8, ekCmyk16
    ekYCbCr8
    ekUnknown

  ExtendedColorType* = object
    case kind*: ExtKind
    of ekUnknown:
      bpp*: uint8
    else:
      discard

  Rgb*[T] = object
    data*: array[3, T]
  Rgba*[T] = object
    data*: array[4, T]
  Luma*[T] = object
    data*: array[1, T]
  LumaA*[T] = object
    data*: array[2, T]

func bytesPerPixel*(c: ColorType): uint8 =
  case c
  of ctL8: 1
  of ctL16, ctLa8: 2
  of ctRgb8: 3
  of ctRgba8, ctLa16, ctL32F: 4
  of ctRgb16: 6
  of ctRgba16, ctLa32F: 8
  of ctRgb32F: 12
  of ctRgba32F: 16

func hasAlpha*(c: ColorType): bool =
  case c
  of ctL8, ctL16, ctL32F, ctRgb8, ctRgb16, ctRgb32F: false
  else: true

func hasColor*(c: ColorType): bool =
  case c
  of ctL8, ctL16, ctL32F, ctLa8, ctLa16, ctLa32F: false
  else: true

func bitsPerPixel*(c: ColorType): uint16 =
  uint16(c.bytesPerPixel()) * 8

func channelCount*(c: ColorType): uint8 =
  case c
  of ctL8, ctL16, ctL32F: 1
  of ctLa8, ctLa16, ctLa32F: 2
  of ctRgb8, ctRgb16, ctRgb32F: 3
  of ctRgba8, ctRgba16, ctRgba32F: 4

func channelCount*(c: ExtendedColorType): uint8 =
  case c.kind
  of ekA8, ekL1, ekL2, ekL4, ekL8, ekL16, ekL32F, ekUnknown: 1
  of ekLa1, ekLa2, ekLa4, ekLa8, ekLa16, ekLa32F: 2
  of ekRgb1, ekRgb2, ekRgb4, ekRgb5x1, ekRgb8, ekRgb16, ekRgb32F,
     ekYCbCr8, ekBgr8: 3
  of ekRgba1, ekRgba2, ekRgba4, ekRgba8, ekRgba16, ekRgba32F,
     ekBgra8, ekCmyk8, ekCmyk16: 4

func bitsPerPixel*(c: ExtendedColorType): uint16 =
  case c.kind
  of ekA8: 8
  of ekL1: 1
  of ekLa1: 2
  of ekRgb1: 3
  of ekRgba1: 4
  of ekL2: 2
  of ekLa2: 4
  of ekRgb2: 6
  of ekRgba2: 8
  of ekL4: 4
  of ekLa4: 8
  of ekRgb4: 12
  of ekRgba4: 16
  of ekRgb5x1: 16
  of ekL8: 8
  of ekLa8: 16
  of ekRgb8: 24
  of ekRgba8: 32
  of ekL16: 16
  of ekLa16: 32
  of ekRgb16: 48
  of ekRgba16: 64
  of ekL32F: 32
  of ekLa32F: 64
  of ekRgb32F: 96
  of ekRgba32F: 128
  of ekBgr8: 24
  of ekBgra8: 32
  of ekCmyk8: 32
  of ekCmyk16: 64
  of ekYCbCr8: 24
  of ekUnknown: uint16(c.bpp)

func bufferSize*(c: ExtendedColorType, width, height: uint32): uint64 =
  let bpp = uint64(c.bitsPerPixel())
  let rowPitch = (uint64(width) * bpp + 7) div 8
  rowPitch * uint64(height)

func colorType*(c: ExtendedColorType): tuple[found: bool, ct: ColorType] =
  case c.kind
  of ekL8: (true, ctL8)
  of ekLa8: (true, ctLa8)
  of ekRgb8: (true, ctRgb8)
  of ekRgba8: (true, ctRgba8)
  of ekL16: (true, ctL16)
  of ekLa16: (true, ctLa16)
  of ekRgb16: (true, ctRgb16)
  of ekRgba16: (true, ctRgba16)
  of ekL32F: (true, ctL32F)
  of ekLa32F: (true, ctLa32F)
  of ekRgb32F: (true, ctRgb32F)
  of ekRgba32F: (true, ctRgba32F)
  else: (false, ctL8)

func toExtended*(c: ColorType): ExtendedColorType =
  case c
  of ctL8: ExtendedColorType(kind: ekL8)
  of ctLa8: ExtendedColorType(kind: ekLa8)
  of ctRgb8: ExtendedColorType(kind: ekRgb8)
  of ctRgba8: ExtendedColorType(kind: ekRgba8)
  of ctL16: ExtendedColorType(kind: ekL16)
  of ctLa16: ExtendedColorType(kind: ekLa16)
  of ctRgb16: ExtendedColorType(kind: ekRgb16)
  of ctRgba16: ExtendedColorType(kind: ekRgba16)
  of ctL32F: ExtendedColorType(kind: ekL32F)
  of ctLa32F: ExtendedColorType(kind: ekLa32F)
  of ctRgb32F: ExtendedColorType(kind: ekRgb32F)
  of ctRgba32F: ExtendedColorType(kind: ekRgba32F)

# --- component conversions (FromPrimitive rules) ---

func convU16toU8*(v: uint16): uint8 =
  uint8((uint32(v) + 128) div 257)

func convU8toU16*(v: uint8): uint16 =
  let x = uint64(v)
  uint16((x shl 8) or x)

func convF32toU8*(v: float32): uint8 =
  let x = min(v, 1.0f32)
  uint8(x * 255.0f32 + 0.5f32)

func convF32toU16*(v: float32): uint16 =
  let x = min(v, 1.0f32)
  uint16(x * 65535.0f32 + 0.5f32)

func convU8toF32*(v: uint8): float32 =
  float32(v) / 255.0f32

func convU16toF32*(v: uint16): float32 =
  float32(v) / 65535.0f32

# --- rgb to luma (sRGB coeffs 2126/7152/722) ---

func rgbToLumaU8*(r, g, b: uint8): uint8 =
  const WR: uint32 = 3566837
  const WG: uint32 = 11999065
  const WB: uint32 = 1211315
  uint8((uint32(r) * WR + uint32(g) * WG + uint32(b) * WB + 0x800000'u32) shr 24)

func rgbToLumaU16*(r, g, b: uint16): uint16 =
  let l = uint32(r) * 2126 + uint32(g) * 7152 + uint32(b) * 722
  uint16(l div 10000)

func rgbToLumaF32*(r, g, b: float32): float32 =
  0.2126f32 * r + 0.7152f32 * g + 0.0722f32 * b
