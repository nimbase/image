## Pure-Nim LZW for GIF (LSB) + TIFF (MSB). No C.
import std/tables
import ../image/error

type BitReaderLSB = object
  base: ptr UncheckedArray[uint8]
  len: int
  pos: int       # byte pos
  bitbuf: uint32
  bits: int

proc nextCodeLSB(r: var BitReaderLSB, width: int): tuple[ok: bool, code: int] =
  while r.bits < width:
    if r.pos >= r.len: return (false, 0)
    r.bitbuf = r.bitbuf or (uint32(r.base[r.pos]) shl r.bits)
    inc r.pos; r.bits += 8
  let code = int(r.bitbuf and uint32((1 shl width) - 1))
  r.bitbuf = r.bitbuf shr width; r.bits -= width
  (true, code)

type BitReaderMSB = object
  base: ptr UncheckedArray[uint8]
  len: int
  pos: int
  bitbuf: uint32
  bits: int

proc nextCodeMSB(r: var BitReaderMSB, width: int): tuple[ok: bool, code: int] =
  while r.bits < width:
    if r.pos >= r.len: return (false, 0)
    r.bitbuf = (r.bitbuf shl 8) or uint32(r.base[r.pos])
    inc r.pos; r.bits += 8
  let shift = r.bits - width
  let code = int((r.bitbuf shr shift) and uint32((1 shl width) - 1))
  r.bits = shift
  r.bitbuf = r.bitbuf and ((if shift == 0: 0'u32 else: (1'u32 shl shift) - 1))
  (true, code)

proc decodeLzwCore(data: openArray[uint8], minCodeSize: int, lsb: bool,
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
  var output: seq[uint8] = if expectedLen > 0: newSeqOfCap[uint8](expectedLen) else: @[]
  let basePtr =
    if data.len == 0: nil
    else: cast[ptr UncheckedArray[uint8]](unsafeAddr data[0])
  var rL = BitReaderLSB(base: basePtr, len: data.len)
  var rM = BitReaderMSB(base: basePtr, len: data.len)
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

proc decodeLzwGif*(data: openArray[uint8], minCodeSize: int,
    expectedLen = 0): ImageResult[seq[uint8]] =
  decodeLzwCore(data, minCodeSize, true, expectedLen)

proc decodeLzwTiff*(data: openArray[uint8], expectedLen = 0): ImageResult[seq[uint8]] =
  decodeLzwCore(data, 8, false, expectedLen)

proc encodeLzwGif*(indices: openArray[uint8], minCodeSize: int): seq[uint8] =
  ## Simple GIF LZW encoder: clear + codes + eoi, LSB packing.
  ## Dictionary keys are ints (`prefixCode shl 8 or byte`), so encoding
  ## allocates nothing per pixel (the old string-keyed table built one
  ## short string per input byte).
  let clear = 1 shl minCodeSize
  let eoi = clear + 1
  var width = minCodeSize + 1
  var outBytes = newSeqOfCap[uint8](indices.len)
  var bitbuf = 0'u32; var bits = 0
  template emit(code: int) =
    bitbuf = bitbuf or (uint32(code) shl bits)
    bits += width
    while bits >= 8:
      outBytes.add(uint8(bitbuf and 0xFF))
      bitbuf = bitbuf shr 8; bits -= 8
  var table = initTable[int, int]()
  var nextCode = eoi + 1
  emit(clear)
  if indices.len == 0:
    emit(eoi)
  else:
    var prefix = int(indices[0])
    for i in 1..<indices.len:
      let c = int(indices[i])
      let key = (prefix shl 8) or c
      if table.hasKey(key):
        prefix = table[key]
      else:
        emit(prefix)
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
        prefix = c
    emit(prefix)
    emit(eoi)
  if bits > 0: outBytes.add(uint8(bitbuf and 0xFF))
  outBytes
