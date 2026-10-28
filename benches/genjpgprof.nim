## JPEG profiling fixture generator. Writes decode fixtures to /tmp/jpgprof/
## (kept out of the repo; deterministic synthetic gradients).
##   clue build benches/genjpgprof.nim --release -o:/tmp/genjpgprof && /tmp/genjpgprof
import std/os
import image

proc gradRgb(w, h: int): seq[Rgb[uint8]] =
  result = newSeq[Rgb[uint8]](w * h)
  for y in 0..<h:
    for x in 0..<w:
      result[y * w + x] = Rgb[uint8](data: [uint8((x * 255) div w),
        uint8((y * 255) div h), uint8(((x + y) * 255) div (w + h))])

proc gradLuma(w, h: int): seq[Luma[uint8]] =
  result = newSeq[Luma[uint8]](w * h)
  for y in 0..<h:
    for x in 0..<w:
      result[y * w + x] = Luma[uint8](data: [uint8(((x + y) * 255) div (w + h))])

proc save(path: string, data: seq[uint8]) =
  writeFile(path, cast[string](data))
  echo path, " bytes=", data.len

when isMainModule:
  createDir("/tmp/jpgprof")
  var px = gradRgb(6000, 4000)
  let b24 = encodeJpeg(DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 6000, height: 4000, pixels: move(px))), 90)
  doAssert b24.ok, b24.err.msg
  save("/tmp/jpgprof/base24.jpg", b24.value)

  var gx = gradLuma(6000, 4000)
  let g24 = encodeJpeg(DynamicImage(kind: dkLuma8,
    luma8: GrayImage(width: 6000, height: 4000, pixels: move(gx))), 90)
  doAssert g24.ok, g24.err.msg
  save("/tmp/jpgprof/gray24.jpg", g24.value)

  var px4 = gradRgb(6000, 4000)
  let c444 = encodeJpeg(DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 6000, height: 4000, pixels: move(px4))), 90,
    subsample = false)
  doAssert c444.ok, c444.err.msg
  save("/tmp/jpgprof/c444_24.jpg", c444.value)

  # odd dims: partial edge MCUs in both axes (6017 = 16*376+1, 4023 = 16*251+7)
  var ox = gradRgb(6017, 4023)
  let odd = encodeJpeg(DynamicImage(kind: dkRgb8,
    rgb8: RgbImage(width: 6017, height: 4023, pixels: move(ox))), 90)
  doAssert odd.ok, odd.err.msg
  save("/tmp/jpgprof/odd.jpg", odd.value)
