## ImageBuffer mirroring references/image/src/images/buffer.rs (subset)
import ./color
import ./error
import ./math

type
  ImageBuffer*[P] = object
    width*: uint32
    height*: uint32
    pixels*: seq[P]

  GrayImage* = ImageBuffer[Luma[uint8]]
  GrayAlphaImage* = ImageBuffer[LumaA[uint8]]
  RgbImage* = ImageBuffer[Rgb[uint8]]
  RgbaImage* = ImageBuffer[Rgba[uint8]]
  Gray16Image* = ImageBuffer[Luma[uint16]]
  GrayAlpha16Image* = ImageBuffer[LumaA[uint16]]
  Rgb16Image* = ImageBuffer[Rgb[uint16]]
  Rgba16Image* = ImageBuffer[Rgba[uint16]]
  Gray32FImage* = ImageBuffer[Luma[float32]]
  GrayAlpha32FImage* = ImageBuffer[LumaA[float32]]
  Rgb32FImage* = ImageBuffer[Rgb[float32]]
  Rgba32FImage* = ImageBuffer[Rgba[float32]]

func newImageBuffer*[P](w, h: uint32, fill: P): ImageBuffer[P] =
  var px = newSeq[P](int(w) * int(h))
  for i in 0..<px.len: px[i] = fill
  ImageBuffer[P](width: w, height: h, pixels: px)

func fromRaw*[P](w, h: uint32, buf: seq[P]): tuple[ok: bool, img: ImageBuffer[P]] =
  if uint64(buf.len) != uint64(w) * uint64(h):
    (false, ImageBuffer[P]())
  else:
    (true, ImageBuffer[P](width: w, height: h, pixels: buf))

func dimensions*[P](img: ImageBuffer[P]): tuple[w, h: uint32] =
  (img.width, img.height)

func inBounds*[P](img: ImageBuffer[P], x, y: uint32): bool =
  x < img.width and y < img.height

func getPixel*[P](img: ImageBuffer[P], x, y: uint32): P =
  img.pixels[int(y) * int(img.width) + int(x)]

proc putPixel*[P](img: var ImageBuffer[P], x, y: uint32, p: P) =
  img.pixels[int(y) * int(img.width) + int(x)] = p

proc cropInPlace*[P](img: var ImageBuffer[P], r: Rect) =
  let (hit, rr) = intersect(r, initRect(0, 0, img.width, img.height))
  if not hit:
    img = ImageBuffer[P](width: 0, height: 0, pixels: @[])
    return
  var outP = newSeq[P](int(rr.width) * int(rr.height))
  for y in 0..<int(rr.height):
    for x in 0..<int(rr.width):
      outP[y * int(rr.width) + x] =
        img.pixels[int(rr.y + uint32(y)) * int(img.width) + int(rr.x + uint32(x))]
  img.width = rr.width
  img.height = rr.height
  img.pixels = outP
