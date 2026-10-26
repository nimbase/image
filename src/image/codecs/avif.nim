## AVIF color math + stubs — references/image/src/codecs/avif/{yuv,ycgco}.rs
## Full AVIF decode needs an AV1 bitstream decoder (out of scope for pure-Nim
## v1); decodeAvif/encodeAvif return Unsupported with a clear message.
## This module ports the reusable color science as scalar reference code:
## BT.601/709/2020 YCbCr (limited + full range, 8-bit, 444/422/420/400)
## and lifted YCgCo-Re forward/inverse (used by AV1 lossless paths).
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic

type
  YuvMatrix* = enum
    ymBT601
    ymBT709
    ymBT2020

  YuvRange* = enum
    yrLimited
    yrFull

func krKb*(m: YuvMatrix): tuple[kr, kb: float64] =
  case m
  of ymBT601: (0.299, 0.114)
  of ymBT709: (0.2126, 0.0722)
  of ymBT2020: (0.2627, 0.0593)

proc yuvToRgbPixel*(y, cb, cr: uint8, m: YuvMatrix,
    r: YuvRange): tuple[r, g, b: uint8] =
  let (kr, kb) = krKb(m)
  let kg = 1.0 - kr - kb
  var fy, fcb, fcr: float64
  if r == yrFull:
    fy = float64(y); fcb = float64(cb) - 128.0; fcr = float64(cr) - 128.0
  else:
    fy = (float64(y) - 16.0) * (255.0 / 219.0)
    fcb = (float64(cb) - 128.0) * (255.0 / 224.0)
    fcr = (float64(cr) - 128.0) * (255.0 / 224.0)
  let rr = fy + 2.0 * (1.0 - kr) * fcr
  let bb = fy + 2.0 * (1.0 - kb) * fcb
  let gg = (fy - kr * rr - kb * bb) / kg
  (uint8(clamp(int(rr + 0.5), 0, 255)),
   uint8(clamp(int(gg + 0.5), 0, 255)),
   uint8(clamp(int(bb + 0.5), 0, 255)))

proc rgbToYuvPixel*(rr, gg, bb: uint8, m: YuvMatrix,
    r: YuvRange): tuple[y, cb, cr: uint8] =
  let (kr, kb) = krKb(m)
  let kg = 1.0 - kr - kb
  let fr = float64(rr); let fg = float64(gg); let fb = float64(bb)
  let fy = kr * fr + kg * fg + kb * fb
  let fcb = (fb - fy) / (2.0 * (1.0 - kb))
  let fcr = (fr - fy) / (2.0 * (1.0 - kr))
  if r == yrFull:
    (uint8(clamp(int(fy + 0.5), 0, 255)),
     uint8(clamp(int(fcb + 128.5), 0, 255)),
     uint8(clamp(int(fcr + 128.5), 0, 255)))
  else:
    (uint8(clamp(int(fy * (219.0 / 255.0) + 16.5), 0, 255)),
     uint8(clamp(int(fcb * (224.0 / 255.0) + 128.5), 0, 255)),
     uint8(clamp(int(fcr * (224.0 / 255.0) + 128.5), 0, 255)))

proc yuv444ToRgb*(y, u, v: seq[uint8], width, height: int, m: YuvMatrix,
    r: YuvRange): RgbImage =
  doAssert y.len == width * height and u.len == width * height and
    v.len == width * height
  var px = newSeq[Rgb[uint8]](width * height)
  for i in 0..<px.len:
    let (rr, gg, bb) = yuvToRgbPixel(y[i], u[i], v[i], m, r)
    px[i] = Rgb[uint8](data: [rr, gg, bb])
  RgbImage(width: uint32(width), height: uint32(height), pixels: px)

proc yuv420ToRgb*(y: seq[uint8], u, v: seq[uint8], width, height: int,
    m: YuvMatrix, r: YuvRange): RgbImage =
  ## 4:2:0 with nearest (top-left) chroma replication.
  doAssert y.len == width * height
  let cw = (width + 1) div 2; let ch = (height + 1) div 2
  doAssert u.len == cw * ch and v.len == cw * ch
  var px = newSeq[Rgb[uint8]](width * height)
  for yy in 0..<height:
    for x in 0..<width:
      let cIdx = (yy div 2) * cw + (x div 2)
      let (rr, gg, bb) = yuvToRgbPixel(y[yy*width+x], u[cIdx], v[cIdx], m, r)
      px[yy*width+x] = Rgb[uint8](data: [rr, gg, bb])
  RgbImage(width: uint32(width), height: uint32(height), pixels: px)

proc yuv422ToRgb*(y: seq[uint8], u, v: seq[uint8], width, height: int,
    m: YuvMatrix, r: YuvRange): RgbImage =
  doAssert y.len == width * height
  let cw = (width + 1) div 2
  doAssert u.len == cw * height and v.len == cw * height
  var px = newSeq[Rgb[uint8]](width * height)
  for yy in 0..<height:
    for x in 0..<width:
      let cIdx = yy * cw + (x div 2)
      let (rr, gg, bb) = yuvToRgbPixel(y[yy*width+x], u[cIdx], v[cIdx], m, r)
      px[yy*width+x] = Rgb[uint8](data: [rr, gg, bb])
  RgbImage(width: uint32(width), height: uint32(height), pixels: px)

proc ycgcoReForward*(r, g, b: int): tuple[y, cg, co: int] =
  ## Lifted YCgCo-Re forward (full range). Inputs 0..maxv.
  let co = r - b
  let t = b + (co shr 1)
  let cg = g - t
  (t + (cg shr 1), cg, co)

proc ycgcoReInverse*(y, cg, co: int): tuple[r, g, b: int] =
  let t = y - (cg shr 1)
  let g = cg + t
  let b = t - (co shr 1)
  (co + b, g, b)

proc decodeAvif*(data: seq[uint8]): ImageResult[DynamicImage] =
  ## AV1 bitstream decoding is out of scope for pure-Nim v1.
  if data.len < 12:
    return err[DynamicImage](decodingError("avif: too short"))
  err[DynamicImage](unsupportedError(ukFormat,
    "avif: AV1 bitstream decoding not implemented in pure-Nim v1"))

proc encodeAvif*(img: DynamicImage): ImageResult[seq[uint8]] =
  err[seq[uint8]](unsupportedError(ukFormat,
    "avif: AV1 bitstream encoding not implemented in pure-Nim v1"))
