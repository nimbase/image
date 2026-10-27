## VP8 unit vectors ported from image-webp src/yuv.rs tests.
## (Full-pipeline exactness vs dwebp lives in t_webp "webp lossy vp8".)
import unittest
import image/codecs/vp8

test "vp8 yuv conversions":
  check yuvToR(203, 42) == 80
  check yuvToG(203, 40, 42) == 255
  check yuvToB(203, 40) == 40

test "vp8 fancy grid":
  # fillRgbFancy consumes padded-stride planes like the real decoder
  # (bufW = 16): rows beyond width/height are ignored.
  var y = newSeq[uint8](16 * 16)
  let y4 = @[77'u8, 162, 202, 185,
    28'u8, 13, 199, 182,
    135'u8, 147, 164, 135,
    66'u8, 27, 171, 130]
  for r in 0..<4:
    for c in 0..<4: y[r * 16 + c] = y4[r * 4 + c]
  var u = newSeq[uint8](8 * 8)
  var v = newSeq[uint8](8 * 8)
  let u2 = @[34'u8, 101, 123, 163]
  let v2 = @[97'u8, 167, 149, 23]
  for r in 0..<2:
    for c in 0..<2:
      u[r * 8 + c] = u2[r * 2 + c]
      v[r * 8 + c] = v2[r * 2 + c]
  let f = Vp8Frame(width: 4, height: 4, ybuf: y, ubuf: u, vbuf: v)
  let rgb = vp8ToRgb(f)
  check rgb.len == 48
  # hardcoded upsampled chroma from the reference test (validates indexing)
  let uu = @[34'u8, 51, 84, 101,
    56'u8, 71, 101, 117,
    101'u8, 112, 136, 148,
    123'u8, 133, 153, 163]
  let vv = @[97'u8, 115, 150, 167,
    110'u8, 115, 126, 131,
    136'u8, 117, 78, 59,
    149'u8, 118, 55, 23]
  for i in 0..<16:
    check rgb[3 * i] == yuvToR(y4[i], vv[i])
    check rgb[3 * i + 1] == yuvToG(y4[i], uu[i], vv[i])
    check rgb[3 * i + 2] == yuvToB(y4[i], uu[i])
