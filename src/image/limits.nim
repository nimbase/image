## Limits mirroring references/image/src/io/limits.rs
import std/options
import ./error
import ./color

type
  LimitSupport* = object

  Limits* = object
    maxImageWidth*: Option[uint32]
    maxImageHeight*: Option[uint32]
    maxAlloc*: Option[uint64]

func satAdd64(a, b: uint64): uint64 =
  let s = a + b
  if s < a: high(uint64) else: s

func satMul64(a, b: uint64): uint64 =
  if a == 0 or b == 0: 0'u64
  elif a > high(uint64) div b: high(uint64)
  else: a * b

func defaultLimits*(): Limits =
  Limits(maxImageWidth: none(uint32), maxImageHeight: none(uint32),
         maxAlloc: some(512'u64 * 1024 * 1024))

func noLimits*(): Limits =
  Limits(maxImageWidth: none(uint32), maxImageHeight: none(uint32),
         maxAlloc: none(uint64))

proc checkDimensions*(l: Limits, w, h: uint32): ImageResult[bool] =
  if l.maxImageWidth.isSome and w > l.maxImageWidth.get:
    return err[bool](limitError(lkDimensionError, "width exceeds limit"))
  if l.maxImageHeight.isSome and h > l.maxImageHeight.get:
    return err[bool](limitError(lkDimensionError, "height exceeds limit"))
  ok(true)

proc reserve*(l: var Limits, amount: uint64): ImageResult[bool] =
  if l.maxAlloc.isSome:
    if l.maxAlloc.get < amount:
      return err[bool](limitError(lkInsufficientMemory, "allocation limit exceeded"))
    l.maxAlloc = some(l.maxAlloc.get - amount)
  ok(true)

proc free*(l: var Limits, amount: uint64) =
  if l.maxAlloc.isSome:
    l.maxAlloc = some(satAdd64(l.maxAlloc.get, amount))

proc reserveBuffer*(l: var Limits, w, h: uint32, c: ColorType): ImageResult[bool] =
  let d = l.checkDimensions(w, h)
  if not d.ok: return d
  let size = satMul64(satMul64(uint64(w), uint64(h)), uint64(c.bytesPerPixel()))
  l.reserve(size)
