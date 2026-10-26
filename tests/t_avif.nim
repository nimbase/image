import unittest
import image
import image/codecs/avif

test "avif yuv round-trip":
  for m in [ymBT601, ymBT709, ymBT2020]:
    for r in [yrFull, yrLimited]:
      for (rr, gg, bb) in [(255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8),
          (0'u8, 0'u8, 255'u8), (128'u8, 128'u8, 128'u8), (16'u8, 32'u8, 48'u8)]:
        let (y, u, v) = rgbToYuvPixel(rr, gg, bb, m, r)
        let (r2, g2, b2) = yuvToRgbPixel(y, u, v, m, r)
        check abs(int(r2) - int(rr)) <= 2
        check abs(int(g2) - int(gg)) <= 2
        check abs(int(b2) - int(bb)) <= 2

test "avif yuv420/422/444":
  let w = 4; let h = 4
  var y = newSeq[uint8](w*h); var u = newSeq[uint8]((w div 2)*(h div 2))
  var v = newSeq[uint8]((w div 2)*(h div 2))
  for i in 0..<y.len: y[i] = uint8(128 + i)
  for i in 0..<u.len: u[i] = 128; v[i] = 128
  let img = yuv420ToRgb(y, u, v, w, h, ymBT601, yrFull)
  check img.width == 4 and img.height == 4
  # neutral chroma => gray ramp
  check img.pixels[0].data[0] == img.pixels[0].data[1]
  check img.pixels[0].data[1] == img.pixels[0].data[2]
  var y2 = newSeq[uint8](w*h); var u2 = newSeq[uint8](w*h); var v2 = newSeq[uint8](w*h)
  for i in 0..<y2.len: y2[i] = 100; u2[i] = 128; v2[i] = 128
  let img2 = yuv444ToRgb(y2, u2, v2, w, h, ymBT709, yrFull)
  check abs(int(img2.pixels[0].data[0]) - 100) <= 1
  var uh = newSeq[uint8]((w div 2)*h); var vh = newSeq[uint8]((w div 2)*h)
  for i in 0..<uh.len: uh[i] = 128; vh[i] = 128
  let img3 = yuv422ToRgb(y2, uh, vh, w, h, ymBT2020, yrLimited)
  check img3.width == 4

test "avif ycgco round-trip":
  for (r, g, b) in [(0, 0, 0), (255, 255, 255), (255, 0, 0), (0, 255, 0),
      (0, 0, 255), (13, 200, 77)]:
    let (y, cg, co) = ycgcoReForward(r, g, b)
    let (r2, g2, b2) = ycgcoReInverse(y, cg, co)
    check (r2, g2, b2) == (r, g, b)

test "avif stubs":
  check decodeAvif(@[0'u8, 1, 2]).ok == false
  var big = newSeq[uint8](16)
  check decodeAvif(big).ok == false
  let img = DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 1, height: 1,
      pixels: @[Rgb[uint8](data: [1'u8, 2, 3])]))
  check encodeAvif(img).ok == false
