## DynamicImage mirroring references/image/src/images/dynimage.rs (subset)
import std/options
import ./color
import ./error
import ./buffer
import ./format

type
  DynamicKind* = enum
    dkLuma8, dkLumaA8, dkRgb8, dkRgba8
    dkLuma16, dkLumaA16, dkRgb16, dkRgba16
    dkLuma32F, dkLumaA32F, dkRgb32F, dkRgba32F

  DynamicImage* = object
    case kind*: DynamicKind
    of dkLuma8: luma8*: GrayImage
    of dkLumaA8: lumaA8*: GrayAlphaImage
    of dkRgb8: rgb8*: RgbImage
    of dkRgba8: rgba8*: RgbaImage
    of dkLuma16: luma16*: Gray16Image
    of dkLumaA16: lumaA16*: GrayAlpha16Image
    of dkRgb16: rgb16*: Rgb16Image
    of dkRgba16: rgba16*: Rgba16Image
    of dkLuma32F: luma32f*: Gray32FImage
    of dkLumaA32F: lumaA32f*: GrayAlpha32FImage
    of dkRgb32F: rgb32f*: Rgb32FImage
    of dkRgba32F: rgba32f*: Rgba32FImage

func color*(img: DynamicImage): ColorType =
  case img.kind
  of dkLuma8: ctL8
  of dkLumaA8: ctLa8
  of dkRgb8: ctRgb8
  of dkRgba8: ctRgba8
  of dkLuma16: ctL16
  of dkLumaA16: ctLa16
  of dkRgb16: ctRgb16
  of dkRgba16: ctRgba16
  of dkLuma32F: ctL32F
  of dkLumaA32F: ctLa32F
  of dkRgb32F: ctRgb32F
  of dkRgba32F: ctRgba32F

func dimensions*(img: DynamicImage): tuple[w, h: uint32] =
  case img.kind
  of dkLuma8: img.luma8.dimensions()
  of dkLumaA8: img.lumaA8.dimensions()
  of dkRgb8: img.rgb8.dimensions()
  of dkRgba8: img.rgba8.dimensions()
  of dkLuma16: img.luma16.dimensions()
  of dkLumaA16: img.lumaA16.dimensions()
  of dkRgb16: img.rgb16.dimensions()
  of dkRgba16: img.rgba16.dimensions()
  of dkLuma32F: img.luma32f.dimensions()
  of dkLumaA32F: img.lumaA32f.dimensions()
  of dkRgb32F: img.rgb32f.dimensions()
  of dkRgba32F: img.rgba32f.dimensions()

func toRgba8*(img: DynamicImage): RgbaImage =
  case img.kind
  of dkRgba8: img.rgba8
  of dkRgb8:
    let s = img.rgb8
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2], 255'u8])
    RgbaImage(width: s.width, height: s.height, pixels: outP)
  of dkLuma8:
    let s = img.luma8
    var outP = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgba[uint8](data: [p.data[0], p.data[0], p.data[0], 255'u8])
    RgbaImage(width: s.width, height: s.height, pixels: outP)
  else:
    # minimal fallback: blank; full conversions land with codec work
    RgbaImage(width: 0, height: 0, pixels: @[])

func toRgb8*(img: DynamicImage): RgbImage =
  case img.kind
  of dkRgb8: img.rgb8
  of dkRgba8:
    let s = img.rgba8
    var outP = newSeq[Rgb[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Rgb[uint8](data: [p.data[0], p.data[1], p.data[2]])
    RgbImage(width: s.width, height: s.height, pixels: outP)
  else:
    RgbImage(width: 0, height: 0, pixels: @[])

func toLuma8*(img: DynamicImage): GrayImage =
  case img.kind
  of dkLuma8: img.luma8
  of dkRgb8:
    let s = img.rgb8
    var outP = newSeq[Luma[uint8]](s.pixels.len)
    for i, p in s.pixels:
      outP[i] = Luma[uint8](data: [rgbToLumaU8(p.data[0], p.data[1], p.data[2])])
    GrayImage(width: s.width, height: s.height, pixels: outP)
  else:
    GrayImage(width: 0, height: 0, pixels: @[])
