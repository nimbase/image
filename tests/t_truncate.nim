## Truncation robustness: every decoder must return `ok == false`
## (never raise / index defect) on truncated or garbage input.
## Cut points 0/1/2/mid must fail for all codecs. A missing single
## trailing byte must fail except where the format tolerates it by
## design: BMP (row padding), JPEG (missing EOI), QOI (end marker),
## WebP (1-byte VP8L padding tolerance) — probed 2026-10-27.
import unittest
import image
import image/codecs/[bmp, png, jpeg, gif, tiff, ico, hdr, pnm, qoi, tga,
  farbfeld, openexr, webp, avif]

template checkCuts(full: seq[uint8], decode: untyped) =
  ## All hard cuts fail; full input decodes fine.
  check decode(full).ok
  for c in [0, 1, 2, full.len div 2]:
    check decode(full[0..<c]).ok == false
  check decode(@[]).ok == false
  check decode(@[0xDE'u8, 0xAD, 0xBE, 0xEF, 0x00, 0xFF, 0x12, 0x34]).ok == false

template checkCutsStrict(full: seq[uint8], decode: untyped) =
  ## As above + a missing trailing byte also fails.
  checkCuts(full, decode)
  check decode(full[0..^2]).ok == false

test "truncate bmp":
  let img = RgbImage(width: 2, height: 2, pixels: @[
    Rgb[uint8](data: [1'u8, 2, 3]), Rgb[uint8](data: [4'u8, 5, 6]),
    Rgb[uint8](data: [7'u8, 8, 9]), Rgb[uint8](data: [10'u8, 11, 12])])
  checkCuts(encodeBmpRgb8(img), decodeBmp)

test "truncate png":
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 2, height: 2,
    pixels: @[Rgb[uint8](data: [1'u8, 2, 3]), Rgb[uint8](data: [4'u8, 5, 6]),
      Rgb[uint8](data: [7'u8, 8, 9]), Rgb[uint8](data: [10'u8, 11, 12])]))
  checkCutsStrict(encodePng(img).value, decodePng)

test "truncate jpeg":
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 8, height: 8, pixels: newSeq[Rgb[uint8]](64)))
  checkCuts(encodeJpeg(img, 90).value, decodeJpeg)

test "truncate gif":
  let pal = @[(0'u8, 0'u8, 0'u8), (255'u8, 255'u8, 255'u8)]
  checkCutsStrict(encodeGif(@[@[0'u8, 1, 0, 1]], 2, 2, pal), decodeGif)

test "truncate tiff":
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 2, height: 2,
    pixels: @[Rgb[uint8](data: [1'u8, 2, 3]), Rgb[uint8](data: [4'u8, 5, 6]),
      Rgb[uint8](data: [7'u8, 8, 9]), Rgb[uint8](data: [10'u8, 11, 12])]))
  checkCutsStrict(encodeTiff(img).value, decodeTiff)

test "truncate ico":
  let img = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 2, height: 2,
    pixels: @[Rgba[uint8](data: [1'u8, 2, 3, 255]),
      Rgba[uint8](data: [4'u8, 5, 6, 255]),
      Rgba[uint8](data: [7'u8, 8, 9, 255]),
      Rgba[uint8](data: [10'u8, 11, 12, 255])]))
  checkCutsStrict(encodeIco(@[img]).value, decodeIco)

test "truncate hdr":
  let img = Rgb32FImage(width: 2, height: 1, pixels: @[
    Rgb[float32](data: [1.0f32, 0.5, 0.25]),
    Rgb[float32](data: [0.0f32, 0.0, 0.0])])
  checkCutsStrict(encodeHdr(img), decodeHdr)

test "truncate pnm":
  let img = RgbImage(width: 2, height: 2, pixels: @[
    Rgb[uint8](data: [1'u8, 2, 3]), Rgb[uint8](data: [4'u8, 5, 6]),
    Rgb[uint8](data: [7'u8, 8, 9]), Rgb[uint8](data: [10'u8, 11, 12])])
  checkCutsStrict(encodePnmRgb8(img), decodePnm)

test "truncate qoi":
  let img = RgbaImage(width: 2, height: 2, pixels: @[
    Rgba[uint8](data: [1'u8, 2, 3, 255]), Rgba[uint8](data: [4'u8, 5, 6, 255]),
    Rgba[uint8](data: [7'u8, 8, 9, 255]),
    Rgba[uint8](data: [10'u8, 11, 12, 255])])
  checkCuts(encodeQoi(img), decodeQoi)

test "truncate tga":
  let img = RgbImage(width: 2, height: 2, pixels: @[
    Rgb[uint8](data: [1'u8, 2, 3]), Rgb[uint8](data: [4'u8, 5, 6]),
    Rgb[uint8](data: [7'u8, 8, 9]), Rgb[uint8](data: [10'u8, 11, 12])])
  checkCutsStrict(encodeTgaRgb8(img), decodeTga)

test "truncate farbfeld":
  let img = Rgba16Image(width: 2, height: 2, pixels: @[
    Rgba[uint16](data: [1'u16, 2, 3, 4]), Rgba[uint16](data: [5'u16, 6, 7, 8]),
    Rgba[uint16](data: [9'u16, 10, 11, 12]),
    Rgba[uint16](data: [13'u16, 14, 15, 16])])
  checkCutsStrict(encodeFarbfeld(img), decodeFarbfeld)

test "truncate exr":
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 2,
    height: 1, pixels: @[Rgb[float32](data: [1.0f32, 0.5, 0.25]),
      Rgb[float32](data: [0.0f32, 0.0, 0.0])]))
  checkCutsStrict(encodeExr(img).value, decodeExr)

test "truncate webp":
  let img = DynamicImage(kind: dkRgba8,
    rgba8: RgbaImage(width: 4, height: 4, pixels: newSeq[Rgba[uint8]](16)))
  checkCuts(encodeWebp(img).value, decodeWebp)

test "truncate avif":
  check decodeAvif(@[]).ok == false
  check decodeAvif(@[0'u8, 1, 2]).ok == false
  check decodeAvif(@[0'u8, 1, 2, 3, 4, 5, 6, 7]).ok == false
  check decodeAvif(@[0xDE'u8, 0xAD, 0xBE, 0xEF]).ok == false
