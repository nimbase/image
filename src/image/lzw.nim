## Pure-Nim LZW for GIF (LSB) + TIFF (MSB). No C.
import std/tables
import ../image/error

type BitReaderLSB = object
  data: seq[uint8]
  pos: int       # byte pos
  bitbuf: uint32
  bits: int

proc nextCodeLSB(r: var BitReaderLSB, width: int): tuple[ok: bool, code: int] =
  while r.bits < width:
    if r.pos >= r.data.len: return (false, 0)
    r.bitbuf = r.bitbuf or (uint32(r.data[r.pos]) shl r.bits)
    inc r.pos; r.bits += 8
  let code = int(r.bitbuf and uint32((1 shl width) - 1))
  r.bitbuf = r.bitbuf shr width; r.bits -= width
  (true, code)

type BitReaderMSB = object
  data: seq[uint8]
  pos: int
  bitbuf: uint32
  bits: int

proc nextCodeMSB(r: var BitReaderMSB, width: int): tuple[ok: bool, code: int] =
  while r.bits < width:
    if r.pos >= r.data.len: return (false, 0)
    r.bitbuf = (r.bitbuf shl 8) or uint32(r.data[r.pos])
    inc r.pos; r.bits += 8
  let shift = r.bits - width
  let code = int((r.bitbuf shr shift) and uint32((1 shl width) - 1))
  r.bits = shift
  r.bitbuf = r.bitbuf and ((if shift == 0: 0'u32 else: (1'u32 shl shift) - 1))
  (true, code)

proc decodeLzwCore(data: seq[uint8], minCodeSize: int, lsb: bool,
    expectedLen: int): ImageResult[seq[uint8]] =
  if minCodeSize < 2 or minCodeSize > 8:
    return err[seq[uint8]](decodingError("lzw: bad min code size"))
  let clear = 1 shl minCodeSize
  let eoi = clear + 1
  var width = minCodeSize + 1
  var dict: seq[seq[uint8]] = newSeq[seq[uint8]](4096)
  for i in 0..<clear: dict[i] = @[uint8(i)]
  var nextCode = eoi + 1
  var prev: seq[uint8] = @[]
  var output: seq[uint8] = @[]
  var rL = BitReaderLSB(data: data)
  var rM = BitReaderMSB(data: data)
  var first = true
  while true:
    let (ok, code) =
      if lsb: nextCodeLSB(rL, width) else: nextCodeMSB(rM, width)
    if not ok:
      break
    if code == clear:
      width = minCodeSize + 1
      nextCode = eoi + 1
      first = true
      prev = @[]
      continue
    if code == eoi:
      break
    var entry: seq[uint8]
    if code < nextCode and dict[code].len > 0:
      entry = dict[code]
    elif code == nextCode and prev.len > 0:
      entry = prev & prev[0..0]
    else:
      return err[seq[uint8]](decodingError("lzw: bad code"))
    for b in entry:
      output.add(b)
      if expectedLen > 0 and output.len > expectedLen:
        return err[seq[uint8]](decodingError("lzw: output overflow"))
    if not first and prev.len > 0:
      if nextCode < 4096:
        dict[nextCode] = prev & entry[0..0]
        inc nextCode
        # GIF "late change": decoder grows one code after the table fills,
        # matching late-change encoders (the GIF standard). The encoder below
        # delays growth by one more code (strict `>`), keeping the pair aligned.
        if nextCode >= (1 shl width) and width < 12:
          inc width
    first = false
    prev = entry
    if expectedLen > 0 and output.len == expectedLen:
      # keep consuming until eoi? GIF allows trailing; stop here.
      break
  ok(output)

proc decodeLzwGif*(data: seq[uint8], minCodeSize: int,
    expectedLen = 0): ImageResult[seq[uint8]] =
  decodeLzwCore(data, minCodeSize, true, expectedLen)

proc decodeLzwTiff*(data: seq[uint8], expectedLen = 0): ImageResult[seq[uint8]] =
  decodeLzwCore(data, 8, false, expectedLen)

proc encodeLzwGif*(indices: openArray[uint8], minCodeSize: int): seq[uint8] =
  ## Simple GIF LZW encoder: clear + codes + eoi, LSB packing.
  let clear = 1 shl minCodeSize
  let eoi = clear + 1
  var width = minCodeSize + 1
  var outBytes: seq[uint8] = @[]
  var bitbuf = 0'u32; var bits = 0
  template emit(code: int) =
    bitbuf = bitbuf or (uint32(code) shl bits)
    bits += width
    while bits >= 8:
      outBytes.add(uint8(bitbuf and 0xFF))
      bitbuf = bitbuf shr 8; bits -= 8
  var table = initTable[string, int]()
  var nextCode = eoi + 1
  emit(clear)
  if indices.len == 0:
    emit(eoi)
  else:
    var prefix = newString(1); prefix[0] = char(indices[0])
    for i in 1..<indices.len:
      let c = char(indices[i])
      let key = prefix & c
      if table.hasKey(key) or (key.len == 1 and int(uint8(key[0])) < clear):
        prefix = key
      else:
        let prefixCode =
          if prefix.len == 1: int(uint8(prefix[0]))
          else: table[prefix]
        emit(prefixCode)
        if nextCode < 4096:
          table[key] = nextCode
          inc nextCode
          # Late change: delay width growth by one code so the bit stream
          # stays aligned with the decoder above (GIF standard behavior).
          if nextCode > (1 shl width) and width < 12: inc width
        else:
          emit(clear)
          table.clear()
          nextCode = eoi + 1; width = minCodeSize + 1
        prefix = newString(1); prefix[0] = c
    let prefixCode =
      if prefix.len == 1: int(uint8(prefix[0]))
      else: table[prefix]
    emit(prefixCode)
    emit(eoi)
  if bits > 0: outBytes.add(uint8(bitbuf and 0xFF))
  outBytes
