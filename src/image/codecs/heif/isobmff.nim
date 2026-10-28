## ISOBMFF box reader for the HEIF container (clean-room implementation).
## Box framing layout per ISO/IEC 14496-12 §8.3: size(32) + type(4CC), with
## size==1 meaning a 64-bit largesize follows, size==0 meaning "to end of
## file". FullBox adds version(8) + flags(24). No code is taken from any
## existing HEIF implementation; the observed fixture bytes under
## tests/fixtures/heif/ plus the Nokia HEIF technical overview were used only
## to confirm which boxes real writers emit.
import ../../error

type
  HeifDecodeError* = object of CatchableError

proc heifErr*(msg: string): ref HeifDecodeError =
  (ref HeifDecodeError)(msg: msg)

type
  Box* = object
    ## A located box: `typ` is the 4CC, `payloadOff`/`payloadLen` delimit the
    ## payload bytes inside the original buffer.
    typ*: array[4, uint8]
    payloadOff*: int
    payloadLen*: int
    boxOff*: int
    boxLen*: int

func typStr*(b: Box): string =
  result = newString(4)
  for i in 0 ..< 4: result[i] = char(b.typ[i])

func isType*(b: Box, a, c, d, e: char): bool =
  b.typ[0] == uint8(a) and b.typ[1] == uint8(c) and
    b.typ[2] == uint8(d) and b.typ[3] == uint8(e)

func isTypeStr*(b: Box, s: string): bool =
  s.len == 4 and b.typ[0] == uint8(s[0]) and b.typ[1] == uint8(s[1]) and
    b.typ[2] == uint8(s[2]) and b.typ[3] == uint8(s[3])

proc checkRange*(data: seq[uint8], off, n: int, what: string) =
  if off < 0 or n < 0 or off + n > data.len:
    raise heifErr("heif: truncated " & what)

proc readU16BE*(data: seq[uint8], off: int, what = "u16"): uint16 =
  checkRange(data, off, 2, what)
  (uint16(data[off]) shl 8) or uint16(data[off + 1])

proc readU32BE*(data: seq[uint8], off: int, what = "u32"): uint32 =
  checkRange(data, off, 4, what)
  (uint32(data[off]) shl 24) or (uint32(data[off + 1]) shl 16) or
    (uint32(data[off + 2]) shl 8) or uint32(data[off + 3])

proc readU64BE*(data: seq[uint8], off: int, what = "u64"): uint64 =
  checkRange(data, off, 8, what)
  (uint64(data[off]) shl 56) or (uint64(data[off + 1]) shl 48) or
    (uint64(data[off + 2]) shl 40) or (uint64(data[off + 3]) shl 32) or
    (uint64(data[off + 4]) shl 24) or (uint64(data[off + 5]) shl 16) or
    (uint64(data[off + 6]) shl 8) or uint64(data[off + 7])

proc readBoxAt*(data: seq[uint8], off: int): Box =
  ## Locate the box starting at `off`. Raises HeifDecodeError on truncation
  ## or a nonsense size. Never reads past `data.len`.
  checkRange(data, off, 8, "box header")
  var size = uint64(readU32BE(data, off, "box size"))
  var hdr = 8
  if size == 1:
    size = readU64BE(data, off + 8, "largesize")
    hdr = 16
  elif size == 0:
    size = uint64(data.len - off)
  if size < uint64(hdr):
    raise heifErr("heif: bad box size")
  if uint64(off) + size > uint64(data.len):
    raise heifErr("heif: box extends past end of file")
  result.typ[0] = data[off + 4]
  result.typ[1] = data[off + 5]
  result.typ[2] = data[off + 6]
  result.typ[3] = data[off + 7]
  result.boxOff = off
  result.boxLen = int(size)
  result.payloadOff = off + hdr
  result.payloadLen = int(size) - hdr

proc topLevelBoxes*(data: seq[uint8]): seq[Box] =
  ## Walk the whole buffer as a sequence of top-level boxes.
  result = @[]
  var off = 0
  while off < data.len:
    let b = readBoxAt(data, off)
    result.add(b)
    off += b.boxLen

proc childBoxes*(data: seq[uint8], parent: Box, fullBoxSkip = 0): seq[Box] =
  ## Walk boxes nested in `parent.payloadOff`. `fullBoxSkip` skips leading
  ## FullBox fields (e.g. 4 for `meta`'s version+flags) before the children.
  result = @[]
  let start = parent.payloadOff + fullBoxSkip
  let stop = parent.payloadOff + parent.payloadLen
  if start > stop:
    raise heifErr("heif: bad " & parent.typStr() & " payload")
  var off = start
  while off < stop:
    let b = readBoxAt(data, off)
    if off + b.boxLen > stop:
      raise heifErr("heif: child box overflows " & parent.typStr())
    result.add(b)
    off += b.boxLen

proc findChild*(data: seq[uint8], parent: Box, t: string,
    fullBoxSkip = 0): tuple[found: bool, b: Box] =
  for c in childBoxes(data, parent, fullBoxSkip):
    if c.isTypeStr(t):
      return (true, c)
  (false, Box())

proc boxVersion*(data: seq[uint8], b: Box): uint8 =
  checkRange(data, b.payloadOff, 4, b.typStr() & " version")
  data[b.payloadOff]

proc boxFlags*(data: seq[uint8], b: Box): uint32 =
  checkRange(data, b.payloadOff, 4, b.typStr() & " flags")
  (uint32(data[b.payloadOff + 1]) shl 16) or
    (uint32(data[b.payloadOff + 2]) shl 8) or
    uint32(data[b.payloadOff + 3])
