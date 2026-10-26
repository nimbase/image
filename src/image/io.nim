## IO layout types mirroring references/image/src/io.rs
import ./color
import ./error

type
  ImageLayout* = object
    color*: ColorType
    width*: uint32
    height*: uint32

  DecoderPreparedImage* = object
    layout*: ImageLayout

func initLayout*(w, h: uint32, c: ColorType): ImageLayout =
  ImageLayout(color: c, width: w, height: h)

func dimensions*(l: ImageLayout): tuple[w, h: uint32] = (l.width, l.height)

func totalBytes*(l: ImageLayout): uint64 =
  let a = if l.width == 0 or l.height == 0: 0'u64
    elif uint64(l.width) > high(uint64) div uint64(l.height): high(uint64)
    else: uint64(l.width) * uint64(l.height)
  let bpp = uint64(l.color.bytesPerPixel())
  if a == 0 or bpp == 0: 0'u64
  elif a > high(uint64) div bpp: high(uint64)
  else: a * bpp

func totalBytes*(p: DecoderPreparedImage): uint64 = p.layout.totalBytes()

func initPrepared*(w, h: uint32, c: ColorType): DecoderPreparedImage =
  DecoderPreparedImage(layout: initLayout(w, h, c))
