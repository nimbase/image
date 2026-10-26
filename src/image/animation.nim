## Animation framing (GIF/APNG/WebP sequences) — not processing.
import std/options

type
  LoopCount* = object
    case infinite*: bool
    of true: discard
    of false: count*: uint16

func infiniteLoop*(): LoopCount = LoopCount(infinite: true)
func finiteLoop*(n: uint16): LoopCount = LoopCount(infinite: false, count: n)

type
  Delay* = object
    numer*, denom*: uint32

func delayMs*(ms: uint32): Delay = Delay(numer: ms, denom: 1000)

func toMs*(d: Delay): uint32 =
  if d.denom == 0: 0'u32 else: d.numer * 1000 div d.denom

type
  Frame* = object
    width*, height*: uint32
    x*, y*: uint32
    delay*: Delay
    data*: seq[uint8]
