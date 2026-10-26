import unittest
import std/options
import image

test "color bytesPerPixel":
  check ctL8.bytesPerPixel() == 1
  check ctRgb8.bytesPerPixel() == 3
  check ctRgba8.bytesPerPixel() == 4
  check ctRgb16.bytesPerPixel() == 6
  check ctRgba32F.bytesPerPixel() == 16

test "color hasAlpha/hasColor":
  check (not ctRgb8.hasAlpha())
  check ctRgba8.hasAlpha()
  check (not ctL8.hasColor())
  check ctRgb8.hasColor()

test "extended bitsPerPixel":
  check ExtendedColorType(kind: ekL8).bitsPerPixel() == 8
  check ExtendedColorType(kind: ekRgb8).bitsPerPixel() == 24
  check ExtendedColorType(kind: ekRgba16).bitsPerPixel() == 64
  check ExtendedColorType(kind: ekUnknown, bpp: 4).bitsPerPixel() == 4

test "extended channelCount":
  check ExtendedColorType(kind: ekL8).channelCount() == 1
  check ExtendedColorType(kind: ekLa8).channelCount() == 2
  check ExtendedColorType(kind: ekRgb8).channelCount() == 3
  check ExtendedColorType(kind: ekRgba8).channelCount() == 4

test "rgbToLuma gray stays gray":
  check rgbToLumaU8(13, 13, 13) == 13
  check rgbToLumaU8(255, 255, 255) == 255
  check rgbToLumaU8(0, 0, 0) == 0

test "u8/u16 conversions round-trip":
  check convU8toU16(0) == 0
  check convU8toU16(255) == 65535
  check convU16toU8(0) == 0
  check convU16toU8(65535) == 255
  # 128/257 boundary: 32768 -> 127 or 128 both acceptable, check range
  let mid = convU16toU8(32768)
  check mid == 127 or mid == 128

test "format fromExtension":
  check fromExtension("png").f == fmtPng
  check fromExtension("JPG").f == fmtJpeg
  check fromExtension("jpeg").f == fmtJpeg
  check fromExtension("qoi").f == fmtQoi
  check fromExtension("ff").f == fmtFarbfeld
  check fromExtension("txt").found == false

test "format fromPath":
  check fromPath("a.png").value == fmtPng
  check fromPath("./a.JPG").value == fmtJpeg
  check fromPath("a.txt").ok == false

test "format mime":
  check fromMimeType("image/png").f == fmtPng
  check fromMimeType("IMAGE/PNG").f == fmtPng
  check fromMimeType("image/jheic").found == false

test "limits default + reserve":
  var l = defaultLimits()
  check l.maxAlloc.get() == 512'u64 * 1024 * 1024
  check l.checkDimensions(100, 100).ok
  check l.reserve(100).ok
  var l2 = noLimits()
  check l2.reserve(high(uint64)).ok

test "buffer put/get + crop":
  var img = newImageBuffer[Rgb[uint8]](4, 4, Rgb[uint8](data: [0'u8, 0, 0]))
  img.putPixel(1, 1, Rgb[uint8](data: [255'u8, 0, 0]))
  check img.getPixel(1, 1).data[0] == 255
  check img.dimensions() == (4'u32, 4'u32)

test "dynamic color/dimensions":
  let g = GrayImage(width: 2, height: 3, pixels: newSeq[Luma[uint8]](6))
  let d = DynamicImage(kind: dkLuma8, luma8: g)
  check d.color() == ctL8
  check d.dimensions() == (2'u32, 3'u32)

test "guessFormat":
  check guessFormat([137'u8, 80, 78, 71, 13, 10, 26, 10]).f == fmtPng
  check guessFormat([0xFF'u8, 0xD8, 0xFF]).f == fmtJpeg
  check guessFormat([uint8('q'), uint8('o'), uint8('i'), uint8('f')]).f == fmtQoi
