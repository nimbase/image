## OpenEXR codec — references/image/src/codecs/openexr.rs + exr@1.74.0
## Single-part scanline only (tiled/multipart/deep return Unsupported).
## NONE/RLE/ZIP/ZIPS/PXR24/B44/B44A/PIZ/DWAA/DWAB + half/float/uint.
## RLE/ZIP pipeline per OpenEXRCore internal_zip.c / internal_rle.c:
## separate even/odd halves, biased delta (first byte raw, rest cur-prev+128),
## then RLE (neg=literal -c bytes, pos=repeat c+1) / zlib-deflate.
## PXR24 per OpenEXRCore internal_pxr24.c: float->float24, per-row delta,
## MSB-first planes, zlib (reimplemented; no copied code).
## B44/B44A per OpenEXRCore internal_b44.c + internal_b44_table_init.c:
## 4x4 half blocks -> 14 bytes (3 for B44A flat fields), exact
## shift-search, sign-magnitude ordering, exp/log tables for pLinear.
## PIZ per OpenEXRCore internal_piz.c (wavelet + range bitmap) and
## internal_huf.c (canonical Huffman with reversed numeric order,
## zero-run table packing, RLE pseudo-symbol; slow-path decoder).
import std/sequtils
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic
import ../zlibwrap

const ExrMagic* = [0x76'u8, 0x2F, 0x31, 0x01]

proc halfToFloat*(h: uint16): float32 =
  let s = (h shr 15) and 1
  let e = (h shr 10) and 0x1F
  let m = h and 0x3FF
  if e == 0:
    if m == 0:
      return if s == 1: -0.0'f32 else: 0.0'f32
    # Denormal: value is m * 2^-24 (no implicit leading 1).
    return (if s == 1: -1.0'f32 else: 1.0'f32) *
      float32(m) * 5.960464477539063e-08'f32
  elif e == 31:
    if m == 0:
      return cast[float32](if s == 1: 0xFF800000'u32 else: 0x7F800000'u32)
    return cast[float32](0x7FC00000'u32) # NaN
  let bits = (uint32(s) shl 31) or (uint32(int(e) + 112) shl 23) or
    (uint32(m) shl 13)
  cast[float32](bits)

proc floatToHalf*(f: float32): uint16 =
  let x = cast[uint32](f)
  let sign = uint16((x shr 16) and 0x8000)
  let xe = x and 0x7FFFFFFF'u32
  if (x and 0x7FFFFFFF'u32) > 0x7F800000'u32:
    return sign or 0x7E00'u16 # NaN
  if xe == 0x7F800000'u32:
    return sign or 0x7C00'u16 # infinities are preserved (Imath half)
  if xe >= 0x47800000'u32:
    return sign or 0x7BFF'u16 # overflow -> max finite
  elif xe >= 0x38800000'u32:
    # Normal range: round the 23-bit mantissa to 10 bits, ties to even
    # (matches Imath half; truncation here would disagree with reference
    # files on values like -43.333332f32 -> 0xD16B, not 0xD16A).
    let e = (xe shr 23) and 0xFF'u32
    var m = (xe and 0x7FFFFF'u32) + 0xFFF'u32 + ((xe shr 13) and 1'u32)
    var ee = e
    if (m and 0x00800000'u32) != 0:
      m = 0
      ee += 1
    if ee >= 143:
      return sign or 0x7BFF'u16 # rounding carried into inf range
    return sign or uint16(((ee - 112'u32) shl 10) or (m shr 13))
  elif xe >= 0x33800000'u32:
    let e = int(xe shr 23)
    let m = (xe and 0x7FFFFF'u32) or 0x800000'u32
    let shift = 126 - e
    let base = m shr shift
    let rest = m and ((1'u32 shl shift) - 1'u32)
    let halfway = 1'u32 shl (shift - 1)
    let t = base + (if rest > halfway or
      (rest == halfway and (base and 1'u32) != 0): 1'u32 else: 0'u32)
    return sign or uint16(t and 0xFFFF)
  elif xe >= 0x33000000'u32:
    # E=102: value in [2^-25, 2^-24), rounds to 0 or 1 ULP. Exactly 0.5
    # ULP (m32 == 0) ties to even (0); anything above rounds to 1.
    # (Needed by the B44 exp table; plain truncation would give 0 here.)
    if (xe and 0x7FFFFF'u32) != 0: return sign or 1'u16
    return sign
  else:
    sign # underflow -> signed zero

# ---------- whole-buffer interleave + delta steps (exrs optimize_bytes) ----------

proc separateHalves(data: var seq[uint8]) =
  ## Even indices -> first half, odd -> second half (in place via copy).
  let n = data.len
  var tmp = newSeq[uint8](n)
  var j = 0
  var i = 0
  while i < n: tmp[j] = data[i]; inc(j); i += 2
  i = 1
  while i < n: tmp[j] = data[i]; inc(j); i += 2
  data = tmp

proc interleaveHalves(data: var seq[uint8]) =
  let n = data.len
  let half = (n + 1) div 2
  var tmp = newSeq[uint8](n)
  for i in 0..<n div 2:
    tmp[2*i] = data[i]
    tmp[2*i+1] = data[half+i]
  if n mod 2 == 1: tmp[n-1] = data[half-1]
  data = tmp

proc samplesToDifferences(data: var seq[uint8]) =
  ## Biased delta per OpenEXRCore internal_zip.c deconstruct /
  ## internal_rle.c reorder_and_predict: first byte raw, the rest store
  ## (cur - prev + 128). The bias keeps small deltas away from zero bytes
  ## that would confuse the RLE stage. (An unbiased delta would round-trip
  ## against itself but misread every foreign file.)
  if data.len == 0: return
  var prev = data[0]
  for i in 1..<data.len:
    let t = data[i]
    data[i] = t - prev + 128'u8 # wraps mod 256
    prev = t

proc differencesToSamples(data: var seq[uint8]) =
  if data.len == 0: return
  for i in 1..<data.len:
    data[i] = data[i-1] + data[i] - 128'u8 # wraps mod 256

# ---------- scanline layout: planar on disk, chunky in memory ----------
## The file layout stores each scanline channel-contiguous
## ([ch0 row][ch1 row]..., channels alphabetical). Our `full`/`raw`
## buffers are pixel-chunky. These convert at the boundary. (PXR24's
## own transform already produces/consumes planar rows, so it shares
## this boundary too.)

proc planarToChunky*(blk: openArray[uint8], w, rows: int,
    chanBytes: seq[int]): seq[uint8] =
  var coff = newSeq[int](chanBytes.len)
  var stride = 0
  for ci in 0..<chanBytes.len:
    coff[ci] = stride
    stride += chanBytes[ci]
  let lineBytes = w * stride
  result = newSeq[uint8](rows * lineBytes)
  for r in 0..<rows:
    var p = r * lineBytes
    for ci in 0..<chanBytes.len:
      let cb = chanBytes[ci]
      for x in 0..<w:
        let dst = (r * w + x) * stride + coff[ci]
        for b in 0..<cb:
          result[dst + b] = blk[p]; inc(p)

proc chunkyToPlanar*(full: openArray[uint8], w, rows: int,
    chanBytes: seq[int]): seq[uint8] =
  var coff = newSeq[int](chanBytes.len)
  var stride = 0
  for ci in 0..<chanBytes.len:
    coff[ci] = stride
    stride += chanBytes[ci]
  let lineBytes = w * stride
  result = newSeq[uint8](rows * lineBytes)
  for r in 0..<rows:
    var p = r * lineBytes
    for ci in 0..<chanBytes.len:
      let cb = chanBytes[ci]
      for x in 0..<w:
        let src = (r * w + x) * stride + coff[ci]
        for b in 0..<cb:
          result[p] = full[src + b]; inc(p)

# ---------- RLE (biased predictor + counts; see internal_rle.c) ----------

proc rleDecompress(data: openArray[uint8], expected: int): ImageResult[seq[uint8]] =
  var output: seq[uint8] = @[]
  var i = 0
  while i < data.len and output.len != expected:
    let count = cast[int8](data[i]); inc(i)
    if count < 0:
      let k = int(-count)
      if i + k > data.len:
        return err[seq[uint8]](decodingError("exr: truncated RLE literal"))
      for j in 0..<k: output.add(data[i+j])
      i += k
    else:
      if i >= data.len:
        return err[seq[uint8]](decodingError("exr: truncated RLE run"))
      let v = data[i]; inc(i)
      for _ in 0..int(count): output.add(v)
  if output.len != expected:
    return err[seq[uint8]](decodingError("exr: RLE size mismatch"))
  differencesToSamples(output)
  interleaveHalves(output)
  if output.len != expected:
    return err[seq[uint8]](decodingError("exr: RLE size mismatch"))
  ok(output)

proc rleCompress(data: seq[uint8]): seq[uint8] =
  ## Input is planar-per-scanline bytes (disk layout); the biased
  ## predictor + counts match internal_rle.c. Currently unused by the
  ## writer (ZIP/PXR24 only) but kept coherent for a future RLE path.
  var buf = data
  separateHalves(buf)
  samplesToDifferences(buf)
  var output: seq[uint8] = @[]
  var runStart = 0
  var runEnd = 1
  let n = buf.len
  while runStart < n:
    while runEnd < n and buf[runStart] == buf[runEnd] and
        (runEnd - runStart) - 1 < 127:
      inc(runEnd)
    if runEnd - runStart >= 3:
      output.add(uint8(runEnd - runStart - 1))
      output.add(buf[runStart])
      runStart = runEnd
    else:
      while runEnd < n and (
          (runEnd + 1 >= n or buf[runEnd] != buf[runEnd+1]) or
          (runEnd + 2 >= n or buf[runEnd+1] != buf[runEnd+2])
        ) and runEnd - runStart < 127:
        inc(runEnd)
      output.add(uint8(256 - (runEnd - runStart))) # negative count
      for i in runStart..<runEnd: output.add(buf[i])
      runStart = runEnd
      inc(runEnd)
  output

# ---------- PXR24 (Pixar lossy-float; lossless for half/uint) ----------

proc floatToFloat24(f: float32): uint32 =
  ## Round a 32-bit float to the 24-bit representation PXR24 stores
  ## (upper 24 bits; low 8 dropped). Preserves NaN payloads / infinities
  ## per internal_pxr24.c; near-FLT_MAX round-up truncates instead.
  let u = cast[uint32](f)
  let s = u and 0x80000000'u32
  let e = u and 0x7F800000'u32
  let m = u and 0x007FFFFF'u32
  if e == 0x7F800000'u32:
    if m != 0:
      let mm = m shr 8
      let i = (e shr 8) or mm or (if mm == 0: 1'u32 else: 0'u32)
      return (s shr 8) or i
    return (s shr 8) or (e shr 8)
  var i = ((e or m) + (m and 0x80'u32)) shr 8
  if i >= 0x7F8000'u32:
    i = (e or m) shr 8
  (s shr 8) or i

proc pxr24TransformedSize(w, rows: int, chanBytes: seq[int],
    pixelTypes: seq[int32]): int =
  ## Size of the zlib payload input (pre-compression): 4 planes for uint,
  ## 2 for half, 3 for float.
  result = 0
  for ci in 0..<chanBytes.len:
    let planes = if pixelTypes[ci] == 2: 3
      elif chanBytes[ci] == 2: 2 else: 4
    result += rows * w * planes

proc pxr24Undo(decomp: openArray[uint8], w, rows: int, chanBytes: seq[int],
    pixelTypes: seq[int32]): ImageResult[seq[uint8]] =
  ## Reconstruct planar-per-scanline rows from PXR24 plane data
  ## (disk layout; the caller converts to chunky).
  var stride = 0
  for cb in chanBytes: stride += cb
  let lineBytes = w * stride
  var output = newSeq[uint8](rows * lineBytes)
  var p = 0
  var pOut = 0
  for r in 0..<rows:
    for ci in 0..<chanBytes.len:
      let pt = pixelTypes[ci]
      let cb = chanBytes[ci]
      if pt == 2: # float: 3 planes -> 4-byte pixels (low byte zero)
        if p + 3 * w > decomp.len:
          return err[seq[uint8]](decodingError("exr: short pxr24 chunk"))
        var pixel = 0'u32
        for x in 0..<w:
          let diff = (uint32(decomp[p + x]) shl 24) or
            (uint32(decomp[p + w + x]) shl 16) or
            (uint32(decomp[p + 2 * w + x]) shl 8)
          pixel += diff # wraps mod 2^32
          let o = pOut + x * cb
          output[o] = uint8(pixel and 0xFF)
          output[o+1] = uint8((pixel shr 8) and 0xFF)
          output[o+2] = uint8((pixel shr 16) and 0xFF)
          output[o+3] = uint8((pixel shr 24) and 0xFF)
        p += 3 * w
        pOut += w * cb
      elif cb == 2: # half: 2 planes
        if p + 2 * w > decomp.len:
          return err[seq[uint8]](decodingError("exr: short pxr24 chunk"))
        var pixel = 0'u32
        for x in 0..<w:
          let diff = (uint32(decomp[p + x]) shl 8) or uint32(decomp[p + w + x])
          pixel += diff
          let o = pOut + x * cb
          output[o] = uint8(pixel and 0xFF)
          output[o+1] = uint8((pixel shr 8) and 0xFF)
        p += 2 * w
        pOut += w * cb
      else: # uint: 4 planes
        if p + 4 * w > decomp.len:
          return err[seq[uint8]](decodingError("exr: short pxr24 chunk"))
        var pixel = 0'u32
        for x in 0..<w:
          let diff = (uint32(decomp[p + x]) shl 24) or
            (uint32(decomp[p + w + x]) shl 16) or
            (uint32(decomp[p + 2 * w + x]) shl 8) or
            uint32(decomp[p + 3 * w + x])
          pixel += diff
          let o = pOut + x * cb
          output[o] = uint8(pixel and 0xFF)
          output[o+1] = uint8((pixel shr 8) and 0xFF)
          output[o+2] = uint8((pixel shr 16) and 0xFF)
          output[o+3] = uint8((pixel shr 24) and 0xFF)
        p += 4 * w
        pOut += w * cb
  ok(output)

proc pxr24Apply(blk: openArray[uint8], w, rows: int, chanBytes: seq[int],
    pixelTypes: seq[int32]): seq[uint8] =
  ## Forward PXR24 transform: per-row/channel delta + MSB-first planes.
  ## Input is chunky rows; output is the planar zlib payload.
  var stride = 0
  var coff = newSeq[int](chanBytes.len)
  for ci in 0..<chanBytes.len:
    coff[ci] = stride
    stride += chanBytes[ci]
  let lineBytes = w * stride
  var output = newSeq[uint8](pxr24TransformedSize(w, rows, chanBytes, pixelTypes))
  var p = 0
  for r in 0..<rows:
    let lineOff = r * lineBytes
    for ci in 0..<chanBytes.len:
      let pt = pixelTypes[ci]
      let cb = chanBytes[ci]
      if pt == 2: # float -> float24
        var prev = 0'u32
        for x in 0..<w:
          let o = lineOff + x * stride + coff[ci]
          let u = uint32(blk[o]) or (uint32(blk[o+1]) shl 8) or
            (uint32(blk[o+2]) shl 16) or (uint32(blk[o+3]) shl 24)
          let cur = floatToFloat24(cast[float32](u))
          let diff = cur - prev # wraps
          prev = cur
          output[p + x] = uint8((diff shr 16) and 0xFF)
          output[p + w + x] = uint8((diff shr 8) and 0xFF)
          output[p + 2 * w + x] = uint8(diff and 0xFF)
        p += 3 * w
      elif cb == 2: # half
        var prev = 0'u32
        for x in 0..<w:
          let o = lineOff + x * stride + coff[ci]
          let cur = uint32(blk[o]) or (uint32(blk[o+1]) shl 8)
          let diff = cur - prev
          prev = cur
          output[p + x] = uint8((diff shr 8) and 0xFF)
          output[p + w + x] = uint8(diff and 0xFF)
        p += 2 * w
      else: # uint
        var prev = 0'u32
        for x in 0..<w:
          let o = lineOff + x * stride + coff[ci]
          let cur = uint32(blk[o]) or (uint32(blk[o+1]) shl 8) or
            (uint32(blk[o+2]) shl 16) or (uint32(blk[o+3]) shl 24)
          let diff = cur - prev
          prev = cur
          output[p + x] = uint8((diff shr 24) and 0xFF)
          output[p + w + x] = uint8((diff shr 16) and 0xFF)
          output[p + 2 * w + x] = uint8((diff shr 8) and 0xFF)
          output[p + 3 * w + x] = uint8(diff and 0xFF)
        p += 4 * w
  output

type ExrChannel* = object
  name*: string
  pixelType*: int32 # 0=uint 1=half 2=float
  pLinear*: bool
  xSamp*, ySamp*: int32

# ---------- PIZ (wavelet + custom Huffman, lossless) ----------
# Reimplements OpenEXRCore internal_piz.c (bitmap LUT, wenc/wdec 14/16,
# 2D wavelet, channel-major scratch) and the slow-path decoder plus the
# faithful encoder of internal_huf.c (canonical codes with reversed
# numeric order, zero-run table packing, RLE pseudo-symbol). The fast
# SIMD decoder is an optimization only; the slow path defines conformance.

const
  HufEncBits = 16
  HufDecBits = 14
  HufEncSize = (1 shl HufEncBits) + 1 # 65537 (u16 symbols + RLE pseudo)
  HufDecSize = 1 shl HufDecBits
  HufDecMask = HufDecSize - 1
  ShortZeroRun = 59
  LongZeroRun = 63
  ShortestLongRun = 2 + LongZeroRun - ShortZeroRun # 6
  LongestLongRun = 255 + ShortestLongRun # 261

type HufDecEntry = object
  len: int32
  lit: uint32
  p: seq[uint32] # long-code symbol list

proc hufGetBits(nBits: int, c: var uint64, lc: var int,
    data: openArray[uint8], pos: var int): uint64 =
  ## MSB-first bit reader shared by table unpacking.
  while lc < nBits:
    c = (c shl 8) or uint64(data[pos]); inc(pos)
    lc += 8
  lc -= nBits
  result = (c shr lc) and ((1'u64 shl nBits) - 1'u64)

proc hufCanonicalCodeTable*(hcode: var openArray[uint64]) =
  ## Canonical codes, reversed numeric order: shorter codes (zero-filled
  ## right) are numerically larger; same-length codes grow with symbols.
  ## Table derivable from lengths alone (not transmitted).
  var n = newSeq[uint64](59)
  for i in 0..<HufEncSize: n[hcode[i]] += 1
  var c = 0'u64
  for i in countdown(58, 1):
    let nc = (c + n[i]) shr 1
    n[i] = c
    c = nc
  for i in 0..<HufEncSize:
    let l = hcode[i]
    if l > 0: hcode[i] = l or (n[l] shl 6); inc(n[l])

proc hufFHeapGreater(a, b: int, frq: openArray[uint64]): bool {.inline.} =
  ## Heap order (min-heap on frequency, ties broken by higher index
  ## first, matching the reference's pointer comparison).
  frq[a] > frq[b] or (frq[a] == frq[b] and a > b)

proc hufInternPushHeap(fHeap: var openArray[int], holeIndex, topIndex: int,
    value: int, frq: openArray[uint64]) =
  var hole = holeIndex
  var parent = (hole - 1) div 2
  while hole > topIndex and hufFHeapGreater(fHeap[parent], value, frq):
    fHeap[hole] = fHeap[parent]
    hole = parent
    parent = (hole - 1) div 2
  fHeap[hole] = value

proc hufAdjustHeap(fHeap: var openArray[int], holeIndex, len: int,
    value: int, frq: openArray[uint64]) =
  let topIndex = holeIndex
  var hole = holeIndex
  var secondChild = holeIndex
  while secondChild < (len - 1) div 2:
    secondChild = 2 * (secondChild + 1)
    if hufFHeapGreater(fHeap[secondChild], fHeap[secondChild - 1], frq):
      dec(secondChild)
    fHeap[hole] = fHeap[secondChild]
    hole = secondChild
  if (len and 1) == 0 and secondChild == (len - 2) div 2:
    secondChild = 2 * (secondChild + 1)
    fHeap[hole] = fHeap[secondChild - 1]
    hole = secondChild - 1
  hufInternPushHeap(fHeap, hole, topIndex, value, frq)

proc hufPushHeap(fHeap: var openArray[int], last: int,
    frq: openArray[uint64]) =
  hufInternPushHeap(fHeap, last - 1, 0, fHeap[last - 1], frq)

proc hufPopHeap(fHeap: var openArray[int], last: int,
    frq: openArray[uint64]) =
  ## Moves top to [last-1]; heap becomes [0, last-1).
  if last - 0 > 1:
    let top = fHeap[0]
    fHeap[0] = fHeap[last - 1]
    fHeap[last - 1] = top
    hufAdjustHeap(fHeap, 0, last - 1, fHeap[0], frq)

proc hufMakeHeap(fHeap: var openArray[int], len: int,
    frq: openArray[uint64]) =
  if len < 2: return
  var parent = (len - 2) div 2
  while true:
    let value = fHeap[parent]
    hufAdjustHeap(fHeap, parent, len, value, frq)
    if parent == 0: return
    dec(parent)

proc hufBuildEncTable*(frq: var openArray[uint64], iMin, iMax: var int): seq[uint64] =
  ## Huffman code lengths via tree simulation + canonical assignment.
  ## Returns the code table (length | code<<6); sets iMin/iMax (min/max
  ## symbol, iMax including the RLE pseudo-symbol with frequency 1).
  ## frq is destroyed.
  var fHeap = newSeq[int](HufEncSize)
  var hlink = newSeq[int](HufEncSize)
  var scode = newSeq[uint64](HufEncSize)
  iMin = 0
  while frq[iMin] == 0: inc(iMin)
  var nf = 0
  var iMv = 0
  for i in iMin..<HufEncSize:
    hlink[i] = i
    if frq[i] != 0:
      fHeap[nf] = i; inc(nf)
      iMv = i
  inc(iMv)
  frq[iMv] = 1
  fHeap[nf] = iMv; inc(nf)
  iMax = iMv
  hufMakeHeap(fHeap, nf, frq)
  while nf > 1:
    let mm = fHeap[0]
    hufPopHeap(fHeap, nf, frq)
    dec(nf)
    let m = fHeap[0]
    hufPopHeap(fHeap, nf, frq)
    frq[m] += frq[mm]
    hufPushHeap(fHeap, nf, frq)
    var j = m
    while true:
      scode[j] += 1
      if hlink[j] == j:
        hlink[j] = mm
        break
      j = hlink[j]
    j = mm
    while true:
      scode[j] += 1
      if hlink[j] == j: break
      j = hlink[j]
  hufCanonicalCodeTable(scode)
  result = scode

proc hufPackEncTable*(hcode: openArray[uint64], iMin, iMax: int): seq[uint8] =
  ## Pack code lengths only (zero runs compressed).
  result = @[]
  var c = 0'u64
  var lc = 0
  var i = iMin
  template outBits(nBits: int, bits: uint64) =
    c = (c shl nBits) or bits
    lc += nBits
    while lc >= 8:
      lc -= 8
      result.add(uint8((c shr lc) and 0xFF))
  while i <= iMax:
    let l = int(hcode[i] and 63)
    if l == 0:
      var zerun = 1
      while i < iMax and zerun < LongestLongRun:
        if int(hcode[i + 1] and 63) > 0: break
        inc(i); inc(zerun)
      if zerun >= 2:
        if zerun >= ShortestLongRun:
          outBits(6, LongZeroRun.uint64)
          outBits(8, uint64(zerun - ShortestLongRun))
        else:
          outBits(6, uint64(ShortZeroRun + zerun - 2))
        inc(i)
        continue
    outBits(6, uint64(l))
    inc(i)
  if lc > 0:
    result.add(uint8((c shl (8 - lc)) and 0xFF))

proc hufUnpackEncTable*(data: openArray[uint8], pos: var int,
    iMin, iMax: int, hcode: var openArray[uint64]): bool =
  ## Unpack lengths; returns false on corrupt input.
  for i in 0..<HufEncSize: hcode[i] = 0
  var c = 0'u64
  var lc = 0
  var di = pos
  template getBits(nBits: int): uint64 =
    (block:
      while lc < nBits:
        if di >= data.len: return false
        c = (c shl 8) or uint64(data[di]); inc(di)
        lc += 8
      lc -= nBits
      (c shr lc) and ((1'u64 shl nBits) - 1'u64))
  var i = iMin
  while i <= iMax:
    if lc < 6 and di - pos >= data.len: return false
    let l = getBits(6)
    if l == LongZeroRun.uint64:
      if lc < 8 and di - pos >= data.len: return false
      var zerun = int(getBits(8)) + ShortestLongRun
      if i + zerun > iMax + 1: return false
      while zerun > 0:
        hcode[i] = 0; inc(i); dec(zerun)
      dec(i)
    elif l >= ShortZeroRun.uint64:
      let zerun = int(l) - ShortZeroRun + 2
      if i + zerun > iMax + 1: return false
      for _ in 0..<zerun:
        hcode[i] = 0; inc(i)
      dec(i)
    else:
      hcode[i] = l
    inc(i)
  pos = di
  hufCanonicalCodeTable(hcode)
  true

proc hufOutCode(code: uint64, c: var uint64, lc, nBits: var int,
    outB: var seq[uint8]) =
  let nB = int(code and 63)
  c = (c shl nB) or (code shr 6)
  lc += nB
  nBits += nB
  while lc >= 8:
    lc -= 8
    outB.add(uint8((c shr lc) and 0xFF))

proc hufSendCode(sCode: uint64, runCount: int, runCode: uint64,
    c: var uint64, lc, nBits: var int, outB: var seq[uint8]) =
  if (int(sCode and 63) + int(runCode and 63) + 8) <
      int(sCode and 63) * runCount:
    hufOutCode(sCode, c, lc, nBits, outB)
    hufOutCode(runCode, c, lc, nBits, outB)
    c = (c shl 8) or uint64(runCount)
    lc += 8
    nBits += 8
    while lc >= 8:
      lc -= 8
      outB.add(uint8((c shr lc) and 0xFF))
  else:
    var rc = runCount
    while rc >= 0:
      hufOutCode(sCode, c, lc, nBits, outB)
      dec(rc)

proc hufEncode*(hcode: openArray[uint64], data: openArray[uint16],
    rlc: int): tuple[bits: seq[uint8], nBits: int] =
  ## Huffman + RLE encode. Returns the packed bit stream and its exact
  ## bit length. Mirrors hufEncode(): a run of cs extras is emitted as
  ## code(s) [, code(rle), 8-bit cs] when shorter, else cs+1 literals.
  var enc: seq[uint8] = @[]
  var c = 0'u64
  var lc = 0
  var nBits = 0
  var s = int(data[0])
  var cs = 0
  let runCode = hcode[rlc]
  for i in 1..<data.len:
    let ns = int(data[i])
    if cs == 255 or s != ns:
      hufSendCode(hcode[s], cs, runCode, c, lc, nBits, enc)
      cs = 0
      s = ns
    else:
      inc(cs)
  hufSendCode(hcode[s], cs, runCode, c, lc, nBits, enc)
  if lc > 0:
    enc.add(uint8((c shl (8 - lc)) and 0xFF))
  (enc, nBits)

proc hufBuildDecTable*(hcode: openArray[uint64], iMin, iMax: int):
    seq[HufDecEntry] =
  ## 14-bit prefix table + long-code lists. Mirrors hufBuildDecTable().
  ## Raises ValueError (caught as corrupt chunk) on table conflicts.
  result = newSeq[HufDecEntry](HufDecSize)
  for i in iMin..iMax:
    let code = hcode[i] shr 6
    let l = int(hcode[i] and 63)
    if (code shr l) != 0 and l > 0:
      raise newException(ValueError, "exr: bad huffman code")
    if l > HufDecBits:
      let pl = int(code shr (l - HufDecBits))
      if result[pl].len != 0:
        raise newException(ValueError, "exr: huffman table clash")
      result[pl].lit += 1
      result[pl].p.add(uint32(i))
    elif l > 0:
      var pl = int(code shl (HufDecBits - l))
      let n = 1 shl (HufDecBits - l)
      for _ in 0..<n:
        if result[pl].len != 0 or result[pl].p.len != 0:
          raise newException(ValueError, "exr: huffman table clash")
        result[pl].len = int32(l)
        result[pl].lit = uint32(i)
        inc(pl)

proc hufDecode*(hcode: openArray[uint64], hdecod: openArray[HufDecEntry],
    data: openArray[uint8], nBits: int, rlc, nOut: int):
    tuple[ok: bool, outp: seq[uint16]] =
  ## Slow-path bit-exact decode with RLE pseudo-symbol handling.
  ## Returns ok=false on any corrupt input (bounds checked throughout).
  var output = newSeq[uint16](nOut)
  var c = 0'u64
  var lc = 0
  var pos = 0
  var n = 0
  let inBytes = (nBits + 7) div 8
  template getChar() =
    if pos >= data.len: return (false, output)
    c = (c shl 8) or uint64(data[pos]); inc(pos)
    lc += 8
  template takeCode(lit: uint32): bool =
    (block:
      var done = true
      if int(lit) == rlc:
        if lc < 8:
          if pos >= data.len: done = false
          else: getChar()
        if done:
          lc -= 8
          let cs = int((c shr lc) and 0xFF)
          if n - 1 < 0: done = false
          elif n + cs > nOut: done = false
          else:
            let sv = output[n - 1]
            for _ in 0..<cs:
              output[n] = sv; inc(n)
      else:
        if n >= nOut: done = false
        else:
          output[n] = uint16(lit); inc(n)
      done)
  while pos < inBytes:
    getChar()
    while lc >= HufDecBits:
      let pl = hdecod[int((c shr (lc - HufDecBits)) and HufDecMask.uint64)]
      if pl.len != 0:
        if pl.len > lc: return (false, output)
        lc -= pl.len
        if not takeCode(pl.lit): return (false, output)
      else:
        if pl.p.len == 0: return (false, output)
        var found = false
        for sym in pl.p:
          let l = int(hcode[sym] and 63)
          while lc < l and pos < inBytes:
            getChar()
          if lc >= l and
              (hcode[sym] shr 6) == ((c shr (lc - l)) and ((1'u64 shl l) - 1'u64)):
            lc -= l
            if not takeCode(sym): return (false, output)
            found = true
            break
        if not found: return (false, output)
  var i = (8 - nBits) and 7
  if i > lc: return (false, output)
  c = c shr i
  lc -= i
  while lc > 0:
    let pl = hdecod[int((c shl (HufDecBits - lc)) and HufDecMask.uint64)]
    if pl.len == 0: return (false, output)
    if pl.len > lc: return (false, output)
    lc -= pl.len
    if not takeCode(pl.lit): return (false, output)
  if n != nOut: return (false, output)
  (true, output)

# ---------- PIZ wavelet + bitmap (mirrors internal_piz.c) ----------

const PizBitmapSize = 8192 # 65536 bits / 8

proc pizBitmapFromData*(data: openArray[uint16],
    bitmap: var openArray[uint8]): tuple[mn, mx: int] =
  ## Presence bitmap over the value range; bit 0 (value 0) never stored.
  for i in 0..<PizBitmapSize: bitmap[i] = 0
  for v in data:
    bitmap[int(v) shr 3] = bitmap[int(v) shr 3] or (1'u8 shl (int(v) and 7))
  bitmap[0] = bitmap[0] and not 1'u8
  var mn = PizBitmapSize - 1
  var mx = 0
  for i in 0..<PizBitmapSize:
    if bitmap[i] != 0:
      if i < mn: mn = i
      if i > mx: mx = i
  (mn, mx)

proc pizForwardLut*(bitmap: openArray[uint8], lut: var openArray[uint16]): int =
  ## Compress the value range: maps every present value (plus 0) to a
  ## dense index. Returns max index.
  var k = 0
  for i in 0..<65536:
    if i == 0 or (bitmap[i shr 3] and (1'u8 shl (i and 7))) != 0:
      lut[i] = uint16(k); inc(k)
  k - 1

proc pizReverseLut*(bitmap: openArray[uint8], lut: var openArray[uint16]): int =
  ## Inverse mapping (dense index -> original value). Returns max index.
  var k = 0
  for i in 0..<65536:
    if i == 0 or (bitmap[i shr 3] and (1'u8 shl (i and 7))) != 0:
      lut[k] = uint16(i); inc(k)
  let n = k - 1
  while k < 65536:
    lut[k] = 0; inc(k)
  n

proc pizApplyLut*(lut: openArray[uint16], data: var openArray[uint16]) =
  for i in 0..<data.len: data[i] = lut[int(data[i])]

proc pizWenc14(a, b: uint16, l, h: var uint16) =
  let ms = (int(cast[int16](a)) + int(cast[int16](b))) shr 1
  # NB: C++ implementation-defined for negatives; arithmetic shift assumed
  let ds = int(cast[int16](a)) - int(cast[int16](b))
  l = uint16(ms and 0xFFFF)
  h = uint16(ds and 0xFFFF)

proc pizWdec14(l, h: uint16, a, b: var uint16) =
  let hi = int(cast[int16](h))
  let li = int(cast[int16](l))
  let ai = li + (hi and 1) + (hi shr 1)
  a = uint16(ai and 0xFFFF)
  b = uint16((ai - hi) and 0xFFFF)

proc pizWdec14x4(px, p01, p10, p11: var uint16) =
  ## Inverse 2D step (wdec14_4): decodes the 2x2 block in place.
  var ai = int(cast[int16](px))
  var bi = int(cast[int16](p10))
  var ci = int(cast[int16](p01))
  var di = int(cast[int16](p11))
  var i00 = ai + (bi and 1) + (bi shr 1)
  let i10 = i00 - bi
  var i01 = ci + (di and 1) + (di shr 1)
  let i11 = i01 - di
  ai = i00 + (i01 and 1) + (i01 shr 1)
  bi = ai - i01
  ci = i10 + (i11 and 1) + (i11 shr 1)
  di = ci - i11
  px = uint16(ai and 0xFFFF)
  p01 = uint16(bi and 0xFFFF)
  p10 = uint16(ci and 0xFFFF)
  p11 = uint16(di and 0xFFFF)

const PizModMask = (1 shl 16) - 1
const PizAOffset = 1 shl 15
const PizMOffset = 1 shl 15

proc pizWenc16(a, b: uint16, l, h: var uint16) =
  let ao = (int(a) + PizAOffset) and PizModMask
  var m = (ao + int(b)) shr 1
  var d = ao - int(b)
  if d < 0: m = (m + PizMOffset) and PizModMask
  d = d and PizModMask
  l = uint16(m)
  h = uint16(d)

proc pizWdec16(l, h: uint16, a, b: var uint16) =
  let m = int(l)
  let d = int(h)
  let bb = (m - (d shr 1)) and PizModMask
  let aa = (d + bb - PizAOffset) and PizModMask
  b = uint16(bb)
  a = uint16(aa)

proc pizWav2DEncode*(buf: var openArray[uint16], nx, ox, ny, oy: int,
    maxVal: uint16) =
  ## Forward 2D Haar-ish transform, in place, strided. Mirrors wav_2D_encode.
  let w14 = if maxVal < (1'u16 shl 14): 1 else: 0
  let n = if nx < ny: nx else: ny
  var p = 1
  var p2 = 2
  while p2 <= n:
    var py = 0
    while py <= oy * (ny - p2):
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox * p
        let p10 = px + oy * p
        let p11 = p10 + ox * p
        if w14 == 1:
          var i00, i01, i10, i11: uint16
          pizWenc14(buf[px], buf[p01], i00, i01)
          pizWenc14(buf[p10], buf[p11], i10, i11)
          pizWenc14(i00, i10, buf[px], buf[p10])
          pizWenc14(i01, i11, buf[p01], buf[p11])
        else:
          var i00, i01, i10, i11: uint16
          pizWenc16(buf[px], buf[p01], i00, i01)
          pizWenc16(buf[p10], buf[p11], i10, i11)
          pizWenc16(i00, i10, buf[px], buf[p10])
          pizWenc16(i01, i11, buf[p01], buf[p11])
        px += ox * p2
      if (nx and p) != 0:
        let p10 = px + oy * p
        if w14 == 1:
          var l, h: uint16
          pizWenc14(buf[px], buf[p10], l, h)
          buf[px] = l; buf[p10] = h
        else:
          var l, h: uint16
          pizWenc16(buf[px], buf[p10], l, h)
          buf[px] = l; buf[p10] = h
      py += oy * p2
    if (ny and p) != 0:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox * p
        if w14 == 1:
          var l, h: uint16
          pizWenc14(buf[px], buf[p01], l, h)
          buf[px] = l; buf[p01] = h
        else:
          var l, h: uint16
          pizWenc16(buf[px], buf[p01], l, h)
          buf[px] = l; buf[p01] = h
        px += ox * p2
    p = p2
    p2 = p2 shl 1

proc pizWav2DDecode*(buf: var openArray[uint16], nx, ox, ny, oy: int,
    maxVal: uint16) =
  ## Inverse 2D transform, in place, strided. Mirrors wav_2D_decode.
  let w14 = if maxVal < (1'u16 shl 14): 1 else: 0
  let n = if nx < ny: nx else: ny
  var p = 1
  while p <= n: p = p shl 1
  p = p shr 1
  var p2 = p
  p = p shr 1
  while p >= 1:
    var py = 0
    while py <= oy * (ny - p2):
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox * p
        let p10 = px + oy * p
        let p11 = p10 + ox * p
        if w14 == 1:
          pizWdec14x4(buf[px], buf[p01], buf[p10], buf[p11])
        else:
          var i00, i10, i01, i11: uint16
          pizWdec16(buf[px], buf[p10], i00, i10)
          pizWdec16(buf[p01], buf[p11], i01, i11)
          pizWdec16(i00, i01, buf[px], buf[p01])
          pizWdec16(i10, i11, buf[p10], buf[p11])
        px += ox * p2
      if (nx and p) != 0:
        let p10 = px + oy * p
        if w14 == 1:
          var i00: uint16
          pizWdec14(buf[px], buf[p10], i00, buf[p10])
          buf[px] = i00
        else:
          var i00: uint16
          pizWdec16(buf[px], buf[p10], i00, buf[p10])
          buf[px] = i00
      py += oy * p2
    if (ny and p) != 0:
      var px = py
      let ex = py + ox * (nx - p2)
      while px <= ex:
        let p01 = px + ox * p
        if w14 == 1:
          var i00: uint16
          pizWdec14(buf[px], buf[p01], i00, buf[p01])
          buf[px] = i00
        else:
          var i00: uint16
          pizWdec16(buf[px], buf[p01], i00, buf[p01])
          buf[px] = i00
        px += ox * p2
    p2 = p
    p = p shr 1

proc hufCompress*(raw: openArray[uint16]): tuple[ok: bool, packed: seq[uint8]] =
  ## Full Huffman stream: 20-byte header (im, iM, tableLen, nBits, 0),
  ## packed table, packed data. Mirrors internal_huf_compress.
  if raw.len == 0: return (true, @[])
  var frq = newSeq[uint64](HufEncSize)
  for v in raw: frq[int(v)] += 1
  var iMin, iMax: int
  let hcode = hufBuildEncTable(frq, iMin, iMax)
  let table = hufPackEncTable(hcode, iMin, iMax)
  let (bits, nBits) = hufEncode(hcode, raw, iMax)
  let dataLen = (nBits + 7) div 8
  var packed = newSeq[uint8](20 + table.len + dataLen)
  proc putU32(o: int, v: int) =
    packed[o] = uint8(v and 0xFF)
    packed[o+1] = uint8((v shr 8) and 0xFF)
    packed[o+2] = uint8((v shr 16) and 0xFF)
    packed[o+3] = uint8((v shr 24) and 0xFF)
  putU32(0, iMin)
  putU32(4, iMax)
  putU32(8, table.len)
  putU32(12, nBits)
  putU32(16, 0)
  for i, b in table: packed[20 + i] = b
  for i in 0..<dataLen: packed[20 + table.len + i] = bits[i]
  (true, packed)

proc hufDecompress*(comp: openArray[uint8], nRaw: int):
    tuple[ok: bool, raw: seq[uint16]] =
  ## Inverse of hufCompress. Mirrors the slow path of
  ## internal_huf_decompress (prefix table, no SIMD fast path needed
  ## for conformance).
  if comp.len < 20:
    if nRaw == 0: return (true, @[])
    return (false, @[])
  let iMin = int(uint32(comp[0]) or (uint32(comp[1]) shl 8) or
    (uint32(comp[2]) shl 16) or (uint32(comp[3]) shl 24))
  let iMax = int(uint32(comp[4]) or (uint32(comp[5]) shl 8) or
    (uint32(comp[6]) shl 16) or (uint32(comp[7]) shl 24))
  let nBits = int(uint32(comp[12]) or (uint32(comp[13]) shl 8) or
    (uint32(comp[14]) shl 16) or (uint32(comp[15]) shl 24))
  if iMin >= HufEncSize or iMax >= HufEncSize: return (false, @[])
  if iMin > iMax: return (false, @[])
  var hcode = newSeq[uint64](HufEncSize)
  var tpos = 20
  if not hufUnpackEncTable(comp, tpos, iMin, iMax, hcode):
    return (false, @[])
  # nBits counts valid bits from the table end; the stream must fit.
  let avail = (comp.len - tpos) * 8
  if nBits > avail: return (false, @[])
  let hdec = hufBuildDecTable(hcode, iMin, iMax)
  let (ok, output) = hufDecode(hcode, hdec,
    comp.toOpenArray(tpos, comp.len - 1), nBits, iMax, nRaw)
  if not ok: return (false, @[])
  (true, output)

proc pizWavEncodeChunk(wav: var seq[uint16], w, rows: int,
    chanBytes: seq[int], maxVal: uint16) =
  ## Forward wavelet per channel/lane (via contiguous lane buffers).
  ## One lane buffer reused across lanes (fully regathered per lane).
  var lane = newSeq[uint16](rows * w)
  var base = 0
  for ci in 0..<chanBytes.len:
    let wc = chanBytes[ci] div 2
    for j in 0..<wc:
      for y in 0..<rows:
        for x in 0..<w:
          lane[y * w + x] = wav[base + y * w * wc + x * wc + j]
      pizWav2DEncode(lane, w, 1, rows, w, maxVal)
      for y in 0..<rows:
        for x in 0..<w:
          wav[base + y * w * wc + x * wc + j] = lane[y * w + x]
    base += rows * w * wc

proc pizWavDecodeChunk(wav: var seq[uint16], w, rows: int,
    chanBytes: seq[int], maxVal: uint16) =
  ## Inverse wavelet per channel/lane.
  var lane = newSeq[uint16](rows * w)
  var base = 0
  for ci in 0..<chanBytes.len:
    let wc = chanBytes[ci] div 2
    for j in 0..<wc:
      for y in 0..<rows:
        for x in 0..<w:
          lane[y * w + x] = wav[base + y * w * wc + x * wc + j]
      pizWav2DDecode(lane, w, 1, rows, w, maxVal)
      for y in 0..<rows:
        for x in 0..<w:
          wav[base + y * w * wc + x * wc + j] = lane[y * w + x]
    base += rows * w * wc

proc pizApplyChunk*(planar: openArray[uint8], w, rows: int,
    chanBytes: seq[int], ptypes: seq[int32]): tuple[ok: bool, blk: seq[uint8]] =
  ## Full PIZ chunk encode: channel-major gather, bitmap + forward LUT,
  ## wavelet, Huffman. Falls back to raw planar when Huffman (with its
  ## headers) does not win. Mirrors internal_exr_apply_piz.
  var poff = newSeq[int](chanBytes.len)
  var lineBytes = 0
  for ci in 0..<chanBytes.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  let exp = rows * lineBytes
  # gather planar rows -> channel-major u16
  var totalU16 = 0
  for cb in chanBytes: totalU16 += rows * w * (cb div 2)
  var wav = newSeq[uint16](totalU16)
  var base = 0
  for ci in 0..<chanBytes.len:
    let cb = chanBytes[ci]
    let wc = cb div 2
    for y in 0..<rows:
      for x in 0..<w:
        for j in 0..<wc:
          let o = y * lineBytes + poff[ci] + x * cb + 2 * j
          wav[base + y * w * wc + x * wc + j] =
            uint16(planar[o]) or (uint16(planar[o + 1]) shl 8)
    base += rows * w * wc
  var bitmap = newSeq[uint8](PizBitmapSize)
  let (mn, mx) = pizBitmapFromData(wav, bitmap)
  var lut = newSeq[uint16](65536)
  let maxVal = pizForwardLut(bitmap, lut)
  pizApplyLut(lut, wav)
  pizWavEncodeChunk(wav, w, rows, chanBytes, uint16(maxVal))
  let (hok, huf) = hufCompress(wav)
  if not hok:
    return (true, @planar)
  # chunk: minNz(2) maxNz(2) bitmap hufLen(4) hufStream
  let bpl = if mx >= mn: mx - mn + 1 else: 0
  var output = newSeq[uint8](4 + bpl + 4 + huf.len)
  output[0] = uint8(mn and 0xFF); output[1] = uint8(mn shr 8)
  output[2] = uint8(mx and 0xFF); output[3] = uint8(mx shr 8)
  for i in 0..<bpl: output[4 + i] = bitmap[mn + i]
  let hl = huf.len
  output[4 + bpl] = uint8(hl and 0xFF)
  output[4 + bpl + 1] = uint8((hl shr 8) and 0xFF)
  output[4 + bpl + 2] = uint8((hl shr 16) and 0xFF)
  output[4 + bpl + 3] = uint8((hl shr 24) and 0xFF)
  for i in 0..<hl: output[4 + bpl + 4 + i] = huf[i]
  if output.len < exp:
    return (true, output)
  (true, @planar)

proc pizUndoChunk*(comp: openArray[uint8], w, rows: int,
    channels: seq[ExrChannel], chanBytes: seq[int]): ImageResult[seq[uint8]] =
  ## Full PIZ chunk decode to planar-per-scanline rows. Mirrors
  ## internal_exr_undo_piz.
  var poff = newSeq[int](channels.len)
  var lineBytes = 0
  for ci in 0..<channels.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  let exp = rows * lineBytes
  if comp.len == exp:
    # encoder stored the chunk raw (Huffman did not win)
    var blk = newSeq[uint8](exp)
    for i in 0..<exp: blk[i] = comp[i]
    return ok(blk)
  if comp.len < 8:
    return err[seq[uint8]](decodingError("exr: short piz chunk"))
  let minNz = int(uint16(comp[0]) or (uint16(comp[1]) shl 8))
  let maxNz = int(uint16(comp[2]) or (uint16(comp[3]) shl 8))
  if maxNz >= PizBitmapSize:
    return err[seq[uint8]](decodingError("exr: corrupt piz bitmap"))
  let bpl = if maxNz >= minNz: maxNz - minNz + 1 else: 0
  if 4 + bpl + 4 > comp.len:
    return err[seq[uint8]](decodingError("exr: short piz chunk"))
  var bitmap = newSeq[uint8](PizBitmapSize)
  for i in 0..<bpl: bitmap[minNz + i] = comp[4 + i]
  let hoff = 4 + bpl
  let hufLen = int(uint32(comp[hoff]) or (uint32(comp[hoff+1]) shl 8) or
    (uint32(comp[hoff+2]) shl 16) or (uint32(comp[hoff+3]) shl 24))
  if hufLen <= 0 or hoff + 4 + hufLen > comp.len:
    return err[seq[uint8]](decodingError("exr: short piz chunk"))
  var lut = newSeq[uint16](65536)
  let maxVal = pizReverseLut(bitmap, lut)
  var totalU16 = 0
  for cb in chanBytes: totalU16 += rows * w * (cb div 2)
  let (hok, wav0) = hufDecompress(comp.toOpenArray(hoff + 4, hoff + 4 + hufLen - 1),
    totalU16)
  if not hok:
    return err[seq[uint8]](decodingError("exr: corrupt piz huffman"))
  var wav = wav0
  pizWavDecodeChunk(wav, w, rows, chanBytes, uint16(maxVal))
  pizApplyLut(lut, wav)
  # scatter channel-major u16 -> planar rows (LE bytes)
  var output = newSeq[uint8](exp)
  var base = 0
  for ci in 0..<chanBytes.len:
    let cb = chanBytes[ci]
    let wc = cb div 2
    for y in 0..<rows:
      for x in 0..<w:
        for j in 0..<wc:
          let v = wav[base + y * w * wc + x * wc + j]
          let o = y * lineBytes + poff[ci] + x * cb + 2 * j
          output[o] = uint8(v and 0xFF)
          output[o + 1] = uint8(v shr 8)
    base += rows * w * wc
  ok(output)

# ---------- DWAA/DWAB decode (lossy DCT; see openexr_dwa.nim) ----------
include openexr_dwa
include openexr_dwa_enc

# ---------- B44/B44A (fixed-rate lossy for half; float/uint passthrough) ---
# Reimplements OpenEXRCore internal_b44.c (pack/unpack/shift search) and
# internal_b44_table_init.c (exp/log tables for pLinear channels).
# Only the pLinear path needs the tables; all other channels skip them.

var b44ExpTable*: seq[uint16]
var b44LogTable*: seq[uint16]

proc ensureB44Tables*() =
  ## y = exp(x/8), x = 8*log(y) in half, exactly per
  ## internal_b44_table_init.c (float32 libm ops, round-half-even).
  if b44ExpTable.len != 0: return
  b44ExpTable = newSeq[uint16](65536)
  b44LogTable = newSeq[uint16](65536)
  for i in 0..<65536:
    let x = uint16(i)
    # exp table
    if (x and 0x7C00'u16) == 0x7C00'u16:
      b44ExpTable[i] = 0
    elif x >= 0x558C'u16 and x < 0x8000'u16:
      b44ExpTable[i] = 0x7BFF'u16
    else:
      b44ExpTable[i] = floatToHalf(exp(halfToFloat(x) / 8.0f32))
    # log table
    if (x and 0x7C00'u16) == 0x7C00'u16:
      b44LogTable[i] = 0
    elif x > 0x8000'u16:
      b44LogTable[i] = 0
    else:
      b44LogTable[i] = floatToHalf(8.0f32 * ln(halfToFloat(x)))

proc b44ShiftAndRound*(x, shift: int): int =
  ## y = x * 2^-shift rounded to nearest, ties to even.
  var a = x shl 1
  let m = (1 shl shift) - 1
  let s = shift + 1
  let b = (a shr s) and 1
  (a + m + b) shr s

proc b44Pack*(s: array[16, uint16], flatFields, exactMax: bool,
    dst: var array[14, uint8]): int =
  ## Compress one 4x4 half block (sign-magnitude preordered) to 3
  ## (flat fields + B44A) or 14 bytes in `dst`; returns the byte count.
  ## Stack-array form of pack() in internal_b44.c: the per-block temp seq
  ## this replaces was the highest-frequency EXR allocation. Callers that
  ## need a seq can slice `dst.toOpenArray(0, n - 1)`.
  var t: array[16, uint16]
  for i in 0..<16:
    if (s[i] and 0x7C00'u16) == 0x7C00'u16:
      t[i] = 0x8000'u16
    elif (s[i] and 0x8000'u16) != 0:
      t[i] = not s[i]
    else:
      t[i] = s[i] or 0x8000'u16
  var tMax = 0'u16
  for v in t:
    if tMax < v: tMax = v
  var d: array[16, int]
  var r: array[15, int]
  var shift = -1
  var rMin, rMax = 0
  const bias = 0x20
  while true:
    inc(shift)
    for i in 0..<16:
      d[i] = b44ShiftAndRound(int(tMax) - int(t[i]), shift)
    r[0] = d[0]-d[4]+bias; r[1] = d[4]-d[8]+bias; r[2] = d[8]-d[12]+bias
    r[3] = d[0]-d[1]+bias; r[4] = d[4]-d[5]+bias; r[5] = d[8]-d[9]+bias
    r[6] = d[12]-d[13]+bias
    r[7] = d[1]-d[2]+bias; r[8] = d[5]-d[6]+bias; r[9] = d[9]-d[10]+bias
    r[10] = d[13]-d[14]+bias
    r[11] = d[2]-d[3]+bias; r[12] = d[6]-d[7]+bias; r[13] = d[10]-d[11]+bias
    r[14] = d[14]-d[15]+bias
    rMin = r[0]; rMax = r[0]
    for i in 1..<15:
      if rMin > r[i]: rMin = r[i]
      if rMax < r[i]: rMax = r[i]
    if rMin >= 0 and rMax <= 0x3F: break
  if rMin == bias and rMax == bias and flatFields:
    dst[0] = uint8(t[0] shr 8); dst[1] = uint8(t[0]); dst[2] = 0xFC'u8
    return 3
  var t0 = t[0]
  if exactMax:
    t0 = tMax - uint16(d[0] shl shift)
  dst[0] = uint8(t0 shr 8); dst[1] = uint8(t0)
  dst[2] = uint8((shift shl 2) or (r[0] shr 4))
  dst[3] = uint8((r[0] shl 4) or (r[1] shr 2))
  dst[4] = uint8((r[1] shl 6) or r[2])
  dst[5] = uint8((r[3] shl 2) or (r[4] shr 4))
  dst[6] = uint8((r[4] shl 4) or (r[5] shr 2))
  dst[7] = uint8((r[5] shl 6) or r[6])
  dst[8] = uint8((r[7] shl 2) or (r[8] shr 4))
  dst[9] = uint8((r[8] shl 4) or (r[9] shr 2))
  dst[10] = uint8((r[9] shl 6) or r[10])
  dst[11] = uint8((r[11] shl 2) or (r[12] shr 4))
  dst[12] = uint8((r[12] shl 4) or (r[13] shr 2))
  dst[13] = uint8((r[13] shl 6) or r[14])
  14

proc b44Unpack*(b: openArray[uint8], flat: bool): array[16, uint16] =
  ## Inverse of b44Pack (mirrors unpack14/unpack3 in internal_b44.c).
  if flat:
    var s0 = (uint16(b[0]) shl 8) or uint16(b[1])
    if (s0 and 0x8000'u16) != 0: s0 = s0 and 0x7FFF'u16
    else: s0 = not s0
    for i in 0..<16: result[i] = s0
    return
  var s: array[16, uint16]
  s[0] = (uint16(b[0]) shl 8) or uint16(b[1])
  let shift = int(b[2] shr 2)
  let bias = 0x20'u16 shl shift
  # Column-major runs match the pack() diagram (r[0..2] down column 0, …).
  s[4] = uint16(uint32(s[0]) + ((((uint32(b[2]) shl 4) or (uint32(b[3]) shr 4)) and 0x3Fu32) shl shift) - uint32(bias))
  s[8] = uint16(uint32(s[4]) + ((((uint32(b[3]) shl 2) or (uint32(b[4]) shr 6)) and 0x3Fu32) shl shift) - uint32(bias))
  s[12] = uint16(uint32(s[8]) + ((uint32(b[4]) and 0x3Fu32) shl shift) - uint32(bias))
  s[1] = uint16(uint32(s[0]) + ((uint32(b[5]) shr 2) shl shift) - uint32(bias))
  s[5] = uint16(uint32(s[4]) + ((((uint32(b[5]) shl 4) or (uint32(b[6]) shr 4)) and 0x3Fu32) shl shift) - uint32(bias))
  s[9] = uint16(uint32(s[8]) + ((((uint32(b[6]) shl 2) or (uint32(b[7]) shr 6)) and 0x3Fu32) shl shift) - uint32(bias))
  s[13] = uint16(uint32(s[12]) + ((uint32(b[7]) and 0x3Fu32) shl shift) - uint32(bias))
  s[2] = uint16(uint32(s[1]) + ((uint32(b[8]) shr 2) shl shift) - uint32(bias))
  s[6] = uint16(uint32(s[5]) + ((((uint32(b[8]) shl 4) or (uint32(b[9]) shr 4)) and 0x3Fu32) shl shift) - uint32(bias))
  s[10] = uint16(uint32(s[9]) + ((((uint32(b[9]) shl 2) or (uint32(b[10]) shr 6)) and 0x3Fu32) shl shift) - uint32(bias))
  s[14] = uint16(uint32(s[13]) + ((uint32(b[10]) and 0x3Fu32) shl shift) - uint32(bias))
  s[3] = uint16(uint32(s[2]) + ((uint32(b[11]) shr 2) shl shift) - uint32(bias))
  s[7] = uint16(uint32(s[6]) + ((((uint32(b[11]) shl 4) or (uint32(b[12]) shr 4)) and 0x3Fu32) shl shift) - uint32(bias))
  s[11] = uint16(uint32(s[10]) + ((((uint32(b[12]) shl 2) or (uint32(b[13]) shr 6)) and 0x3Fu32) shl shift) - uint32(bias))
  s[15] = uint16(uint32(s[14]) + ((uint32(b[13]) and 0x3Fu32) shl shift) - uint32(bias))
  for i in 0..<16:
    if (s[i] and 0x8000'u16) != 0: s[i] = s[i] and 0x7FFF'u16
    else: s[i] = not s[i]
  s

proc b44ApplyChunk*(planar: openArray[uint8], w, rows: int,
    chanBytes: seq[int], ptypes: seq[int32], pLinears: seq[bool],
    flatFields: bool): seq[uint8] =
  ## Encode one chunk to B44/B44A: 4x4 half blocks via b44Pack (with
  ## edge replication and pLinear exp conversion), float/uint channels
  ## verbatim. Mirrors compress() in internal_b44.c.
  ensureB44Tables()
  var poff = newSeq[int](chanBytes.len)
  var lineBytes = 0
  for ci in 0..<chanBytes.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  result = @[]
  for ci in 0..<chanBytes.len:
    if ptypes[ci] != 1:
      # float/uint ride along verbatim (planar row segments, in order)
      for r in 0..<rows:
        for i in 0..<w * chanBytes[ci]:
          result.add(planar[r * lineBytes + poff[ci] + i])
      continue
    var by = 0
    while by < rows:
      var bx = 0
      while bx < w:
        var s: array[16, uint16]
        for iy in 0..<4:
          let yy = min(by + iy, rows - 1)
          for ix in 0..<4:
            let xx = min(bx + ix, w - 1)
            let o = yy * lineBytes + poff[ci] + xx * 2
            s[iy * 4 + ix] = uint16(planar[o]) or (uint16(planar[o + 1]) shl 8)
        if pLinears[ci]:
          for i in 0..<16: s[i] = b44ExpTable[s[i]]
        var enc: array[14, uint8]
        let n = b44Pack(s, flatFields, not pLinears[ci], enc)
        for i in 0..<n: result.add(enc[i])
        bx += 4
      by += 4

proc b44UndoChunk*(comp: openArray[uint8], w, rows: int,
    channels: seq[ExrChannel], chanBytes: seq[int]): ImageResult[seq[uint8]] =
  ## Decode one B44/B44A chunk to planar-per-scanline rows. Mirrors
  ## uncompress_b44_impl in internal_b44.c (4x4 blocks, edge replication,
  ## flat-field 3-byte form, pLinear log conversion, float/uint passthrough).
  ensureB44Tables()
  # Planar-per-scanline offsets: channel ci's row segment starts at
  # poff[ci] within each row (NOT the chunky within-pixel coff).
  var poff = newSeq[int](channels.len)
  var lineBytes = 0
  for ci in 0..<channels.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  var output = newSeq[uint8](rows * lineBytes)
  var p = 0
  for ci in 0..<channels.len:
    let nx = w
    let ny = rows
    let cb = chanBytes[ci]
    if channels[ci].pixelType != 1:
      # UINT/FLOAT passthrough: planar row segments map straight across.
      if p + ny * nx * cb > comp.len:
        return err[seq[uint8]](decodingError("exr: short b44 chunk"))
      for r in 0..<ny:
        for i in 0..<nx * cb:
          output[r * lineBytes + poff[ci] + i] = comp[p + r * nx * cb + i]
      p += ny * nx * cb
      continue
    var by = 0
    while by < ny:
      var bx = 0
      while bx < nx:
        if p + 3 > comp.len:
          return err[seq[uint8]](decodingError("exr: short b44 chunk"))
        var s: array[16, uint16]
        if comp[p + 2] >= (13 shl 2):
          s = b44Unpack(comp.toOpenArray(p, p + 2), true)
          p += 3
        else:
          if p + 14 > comp.len:
            return err[seq[uint8]](decodingError("exr: short b44 chunk"))
          s = b44Unpack(comp.toOpenArray(p, p + 13), false)
          p += 14
        if channels[ci].pLinear:
          for i in 0..<16: s[i] = b44LogTable[s[i]]
        for iy in 0..<4:
          let yy = by + iy
          if yy >= ny: continue
          for ix in 0..<4:
            let xx = bx + ix
            if xx >= nx: continue
            let v = s[iy * 4 + ix]
            let o = yy * lineBytes + poff[ci] + xx * 2
            output[o] = uint8(v and 0xFF)
            output[o + 1] = uint8(v shr 8)
        bx += 4
      by += 4
  ok(output)

# ---------- header parsing ----------

proc rd32le(d: openArray[uint8], off: int): uint32 =
  uint32(d[off]) or (uint32(d[off+1]) shl 8) or (uint32(d[off+2]) shl 16) or
    (uint32(d[off+3]) shl 24)

proc rdI32le(d: openArray[uint8], off: int): int32 = cast[int32](rd32le(d, off))

proc readName(data: seq[uint8], pos: var int, maxLen: int): tuple[ok: bool, s: string] =
  var s = ""
  while pos < data.len and data[pos] != 0:
    s.add(char(data[pos])); inc(pos)
    if s.len > maxLen: return (false, "")
  if pos >= data.len: return (false, "")
  inc(pos) # skip NUL
  (true, s)

proc decodeExrAll*(data: seq[uint8]): ImageResult[seq[DynamicImage]] =
  if data.len < 8:
    return err[seq[DynamicImage]](decodingError("exr: too short"))
  for i in 0..3:
    if data[i] != ExrMagic[i]:
      return err[seq[DynamicImage]](decodingError("exr: bad magic"))
  let ver = rd32le(data, 4)
  if (ver and 0xFF) != 2:
    return err[seq[DynamicImage]](decodingError("exr: bad version"))
  if (ver and 0x200) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: tiled"))
  if (ver and 0x1000) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: multipart"))
  if (ver and 0x800) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: deep/non-image"))
  var pos = 8
  var channels: seq[ExrChannel] = @[]
  var compression = -1
  var dataWin = [0, 0, -1, -1]
  var dispWin = [0, 0, -1, -1]
  var lineOrder = 0
  while true:
    if pos >= data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated header"))
    if data[pos] == 0:
      inc(pos); break
    let (okN, name) = readName(data, pos, 255)
    if not okN:
      return err[seq[DynamicImage]](decodingError("exr: bad attr name"))
    let (okT, typ) = readName(data, pos, 31)
    if not okT:
      return err[seq[DynamicImage]](decodingError("exr: bad attr type"))
    if pos + 4 > data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated attr size"))
    let size = int(rd32le(data, pos)); pos += 4
    if pos + size > data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated attr"))
    let val = data[pos..<pos+size]; pos += size
    case name
    of "channels":
      var q = 0
      while q < val.len and val[q] != 0:
        # channel name (NUL-terminated)
        var e2 = q
        while e2 < val.len and val[e2] != 0: inc(e2)
        if e2 + 17 > val.len: break
        var nm = ""
        for k in q..<e2: nm.add(char(val[k]))
        let pt = rdI32le(val, e2 + 1)
        let pl = val[e2 + 5] != 0
        let xs = rdI32le(val, e2 + 9)
        let ys = rdI32le(val, e2 + 13)
        channels.add(ExrChannel(name: nm, pixelType: pt, pLinear: pl,
          xSamp: xs, ySamp: ys))
        q = e2 + 17
    of "compression":
      if val.len >= 1: compression = int(val[0])
    of "dataWindow":
      if val.len >= 16:
        for i in 0..3: dataWin[i] = cast[int32](rd32le(val, i*4))
    of "displayWindow":
      if val.len >= 16:
        for i in 0..3: dispWin[i] = cast[int32](rd32le(val, i*4))
    of "lineOrder":
      if val.len >= 1: lineOrder = int(val[0])
    else: discard
  if channels.len == 0 or compression < 0:
    return err[seq[DynamicImage]](decodingError("exr: missing header"))
  if dataWin[2] < dataWin[0] or dataWin[3] < dataWin[1]:
    return err[seq[DynamicImage]](decodingError("exr: bad data window"))
  let w = int(dataWin[2] - dataWin[0] + 1)
  let h = int(dataWin[3] - dataWin[1] + 1)
  if w <= 0 or h <= 0 or w > 1 shl 24 or h > 1 shl 24:
    return err[seq[DynamicImage]](limitError(lkDimensionError, "exr: dimensions"))
  for c in channels:
    if c.xSamp != 1 or c.ySamp != 1:
      return err[seq[DynamicImage]](unsupportedError(ukGenericFeature,
        "exr: subsampled channels"))
    if c.pixelType notin [0'i32, 1, 2]:
      return err[seq[DynamicImage]](unsupportedError(ukColor, "exr: sample type"))
  # Pixel data channels are ALWAYS alphabetical by name (OpenEXR File
  # Layout: "within a scan line the data for each channel are contiguous.
  # Channels are stored in alphabetical order"), independent of chlist
  # order. Sort so coff/stride/getF index the data layout, not the header.
  for i in 1..<channels.len:
    let t = channels[i]
    var j = i - 1
    while j >= 0 and channels[j].name > t.name:
      channels[j+1] = channels[j]; dec(j)
    channels[j+1] = t
  # rows per chunk + bytes per line
  var chanBytes: seq[int] = @[]
  for c in channels:
    chanBytes.add(if c.pixelType == 1: 2 else: 4)
  let lineBytes = block:
    var s = 0
    for i, c in channels: s += w * chanBytes[i]
    s
  let rowsPerChunk =
    case compression
    of 0, 1, 2: 1
    of 3, 5: 16
    of 4, 6, 7, 8: 32
    of 9: 256
    else:
      return err[seq[DynamicImage]](unsupportedError(ukGenericFeature,
        "exr: compression " & $compression))
  let nChunks = (h + rowsPerChunk - 1) div rowsPerChunk
  if pos + 8 * nChunks > data.len:
    return err[seq[DynamicImage]](decodingError("exr: truncated offset table"))
  var offsets = newSeq[uint64](nChunks)
  for i in 0..<nChunks:
    var o = 0'u64
    for b in 0..7: o = o or (uint64(data[pos+i*8+b]) shl (8*b))
    offsets[i] = o
  pos += 8 * nChunks
  # gather (y, bytes) per chunk
  type Chunk = tuple[y: int, raw: seq[uint8]]
  var chunks: seq[Chunk] = @[]
  for i in 0..<nChunks:
    let o = int(offsets[i])
    if o + 8 > data.len:
      return err[seq[DynamicImage]](decodingError("exr: chunk OOB"))
    let y = int(cast[int32](rd32le(data, o)))
    let sz = int(rd32le(data, o + 4))
    if o + 8 + sz > data.len:
      return err[seq[DynamicImage]](decodingError("exr: chunk data OOB"))
    chunks.add((y, data[o+8..<o+8+sz]))
  # sort by y; row mapping per lineOrder
  var order = newSeq[int](chunks.len)
  for i in 0..<order.len: order[i] = i
  # insertion sort by y (chunk counts are small; avoid algorithm import)
  for i in 1..<order.len:
    let t = order[i]
    var j = i - 1
    while j >= 0 and chunks[order[j]].y > chunks[t].y:
      order[j+1] = order[j]; dec(j)
    order[j+1] = t
  var full = newSeq[uint8](h * lineBytes)
  for oi in order:
    let (yAbs, comp) = chunks[oi]
    var firstRow =
      if lineOrder == 1: dataWin[3] - yAbs
      else: yAbs - dataWin[1]
    let rows = min(rowsPerChunk, h - firstRow)
    if firstRow < 0 or rows <= 0: continue
    let exp = rows * lineBytes
    var blk: seq[uint8]
    case compression
    of 0:
      if comp.len < exp:
        return err[seq[DynamicImage]](decodingError("exr: short raw chunk"))
      blk = comp[0..<exp]
    of 1:
      # As with ZIP, the encoder stores the chunk raw when RLE grows it;
      # the reference framework then skips decompression (proven: a
      # raw-stored RLE chunk re-converts byte-identically). Mirror that.
      if comp.len == exp:
        blk = comp[0..<exp]
      else:
        var r = rleDecompress(comp, exp)
        if not r.ok: return err[seq[DynamicImage]](r.err)
        blk = move(r.value)
    of 2, 3:
      # Reference stores whichever is smaller (raw vs deflated); a chunk
      # whose size equals the unpacked size is raw (undo_zip fast path).
      if comp.len == exp:
        blk = comp[0..<exp]
      else:
        var r = inflateZlib(comp, exp)
        if not r.ok: return err[seq[DynamicImage]](r.err)
        if r.value.len < exp:
          return err[seq[DynamicImage]](decodingError("exr: short zip chunk"))
        if r.value.len == exp: blk = move(r.value)
        else: blk = r.value[0..<exp]
        differencesToSamples(blk)
        interleaveHalves(blk)
    of 5:
      # PXR24: zlib payload is plane-split (3 bytes/px for float), so the
      # inflated size differs from exp when float channels are present.
      var ptypes = newSeq[int32](channels.len)
      for i, c in channels: ptypes[i] = c.pixelType
      let tsize = pxr24TransformedSize(w, rows, chanBytes, ptypes)
      var inflated = inflateZlib(comp, tsize)
      if inflated.ok and inflated.value.len >= tsize:
        let decomp = if inflated.value.len == tsize: move(inflated.value)
          else: inflated.value[0..<tsize]
        var u = pxr24Undo(decomp, w, rows, chanBytes, ptypes)
        if not u.ok: return err[seq[DynamicImage]](u.err)
        blk = move(u.value)
      elif comp.len == exp:
        # encoder stored the chunk raw (compressed form was larger)
        blk = comp[0..<exp]
      else:
        if not inflated.ok: return err[seq[DynamicImage]](inflated.err)
        return err[seq[DynamicImage]](decodingError("exr: short pxr24 chunk"))
    of 6, 7:
      # B44/B44A: fixed 14-byte (or 3-byte flat) 4x4 half blocks;
      # float/uint channels ride along uncompressed.
      if comp.len == exp:
        # encoder stored the chunk raw (B44 output larger than input,
        # e.g. tiny images); treat as final planar bytes.
        blk = comp[0..<exp]
      else:
        var u = b44UndoChunk(comp, w, rows, channels, chanBytes)
        if not u.ok: return err[seq[DynamicImage]](u.err)
        blk = move(u.value)
    of 4:
      # PIZ: wavelet + custom Huffman, 32 rows/chunk.
      if comp.len == exp:
        # encoder stored the chunk raw (Huffman did not win).
        blk = comp[0..<exp]
      else:
        var u = pizUndoChunk(comp, w, rows, channels, chanBytes)
        if not u.ok: return err[seq[DynamicImage]](u.err)
        blk = move(u.value)
    of 8, 9:
      # DWAA (32 rows/chunk) / DWAB (256 rows/chunk): lossy DCT.
      if comp.len == exp:
        blk = comp[0..<exp]
      else:
        var u = dwaUndoChunk(comp, w, rows, channels, chanBytes)
        if not u.ok: return err[seq[DynamicImage]](u.err)
        blk = move(u.value)
    else: discard
    # Disk layout is planar-per-scanline for every compression; convert
    # once to our chunky `full` buffer. (PXR24's undo already emits
    # planar rows, so it shares this boundary.)
    blk = planarToChunky(blk, w, rows, chanBytes)
    for r in 0..<rows:
      for i in 0..<lineBytes:
        full[(firstRow+r)*lineBytes+i] = blk[r*lineBytes+i]
  # samples -> DynamicImage (chunky-interleaved rows).
  var coff = newSeq[int](channels.len)
  var stride = 0
  for ci in 0..<channels.len:
    coff[ci] = stride
    stride += chanBytes[ci]
  proc getF(lineOff, x, ci: int): float32 =
    let o = lineOff + x * stride + coff[ci]
    case channels[ci].pixelType
    of 0:
      let u = uint32(full[o]) or (uint32(full[o+1]) shl 8) or
        (uint32(full[o+2]) shl 16) or (uint32(full[o+3]) shl 24)
      float32(u)
    of 1:
      halfToFloat(uint16(full[o]) or (uint16(full[o+1]) shl 8))
    else:
      let u = uint32(full[o]) or (uint32(full[o+1]) shl 8) or
        (uint32(full[o+2]) shl 16) or (uint32(full[o+3]) shl 24)
      cast[float32](u)
  let names = channels.mapIt(it.name)
  proc findCh(nm: string): int =
    for i, n in names:
      if n == nm: return i
    -1
  let ri = findCh("R"); let gi = findCh("G"); let bi = findCh("B")
  let ai = findCh("A"); let yi = findCh("Y")
  if ri >= 0 and gi >= 0 and bi >= 0 and yi < 0:
    var px = newSeq[Rgb[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w:
        px[y*w+x] = Rgb[float32](data: [getF(lo, x, ri), getF(lo, x, gi),
          getF(lo, x, bi)])
    if ai >= 0:
      var pxa = newSeq[Rgba[float32]](w*h)
      for y in 0..<h:
        let lo = y * lineBytes
        for x in 0..<w:
          pxa[y*w+x] = Rgba[float32](data: [getF(lo, x, ri), getF(lo, x, gi),
            getF(lo, x, bi), getF(lo, x, ai)])
      return ok(@[DynamicImage(kind: dkRgba32F, rgba32f:
        Rgba32FImage(width: uint32(w), height: uint32(h), pixels: move(pxa)))])
    return ok(@[DynamicImage(kind: dkRgb32F, rgb32f:
      Rgb32FImage(width: uint32(w), height: uint32(h), pixels: move(px)))])
  elif yi >= 0:
    if ai >= 0:
      var px = newSeq[LumaA[float32]](w*h)
      for y in 0..<h:
        let lo = y * lineBytes
        for x in 0..<w:
          px[y*w+x] = LumaA[float32](data: [getF(lo, x, yi), getF(lo, x, ai)])
      return ok(@[DynamicImage(kind: dkLumaA32F, lumaA32f:
        GrayAlpha32FImage(width: uint32(w), height: uint32(h), pixels: move(px)))])
    var px = newSeq[Luma[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w: px[y*w+x] = Luma[float32](data: [getF(lo, x, yi)])
    return ok(@[DynamicImage(kind: dkLuma32F, luma32f:
      Gray32FImage(width: uint32(w), height: uint32(h), pixels: move(px)))])
  elif ai >= 0 and ri < 0:
    # Alpha-only treated as luma (documented; matches TGA/BMP precedent).
    var pl = newSeq[Luma[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w: pl[y*w+x] = Luma[float32](data: [getF(lo, x, ai)])
    return ok(@[DynamicImage(kind: dkLuma32F, luma32f:
      Gray32FImage(width: uint32(w), height: uint32(h), pixels: move(pl)))])
  return err[seq[DynamicImage]](unsupportedError(ukColor,
    "exr: channel set " & $names))

proc decodeExr*(data: seq[uint8]): ImageResult[DynamicImage] =
  let r = decodeExrAll(data)
  if not r.ok: return err[DynamicImage](r.err)
  ok(r.value[0])

proc putU32le(dst: var seq[uint8], v: uint32) =
  dst.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF),
    uint8((v shr 16) and 0xFF), uint8((v shr 24) and 0xFF)])

proc putAttr(dst: var seq[uint8], name, typ: string, val: seq[uint8]) =
  for c in name: dst.add(uint8(c))
  dst.add(0)
  for c in typ: dst.add(uint8(c))
  dst.add(0)
  putU32le(dst, uint32(val.len))
  for b in val: dst.add(b)

proc putBox(dst: var seq[uint8], x0, y0, x1, y1: int32) =
  for v in [x0, y0, x1, y1]:
    putU32le(dst, cast[uint32](v))

proc encodeExr*(img: DynamicImage, compression: int = 3): ImageResult[seq[uint8]] =
  ## Scanline writer (ZIP default; PXR24/B44/B44A/PIZ opt-in). Accepts
  ## Rgb32F/Rgba32F/Luma32F (convert first). PXR24 rounds float channels
  ## to 24 bits on write (lossy). B44 only compresses half channels, so
  ## this float-only writer stores them uncompressed (spec passthrough).
  ## HALF/UINT-exactness only matters on decode of foreign files.
  ## Channel data is packed alphabetically by name (B,G,R / A,B,G,R),
  ## per the file layout; the chlist is written in the same order.
  if compression notin [3, 4, 5, 6, 7, 8, 9]:
    return err[seq[uint8]](unsupportedError(ukGenericFeature,
      "exr: encode compression " & $compression))
  var w, h: int
  var chNames: seq[string] = @[]
  var raw: seq[uint8] = @[]
  case img.kind
  of dkRgb32F:
    w = int(img.rgb32f.width); h = int(img.rgb32f.height)
    chNames = @["B", "G", "R"]
    const comp = [2, 1, 0] # B,G,R <- R,G,B pixel components
    raw = newSeq[uint8](w*h*12)
    for i, p in img.rgb32f.pixels:
      for c in 0..2:
        let u = cast[uint32](p.data[comp[c]])
        raw[12*i+4*c]=uint8(u and 0xFF); raw[12*i+4*c+1]=uint8((u shr 8) and 0xFF)
        raw[12*i+4*c+2]=uint8((u shr 16) and 0xFF); raw[12*i+4*c+3]=uint8((u shr 24) and 0xFF)
  of dkRgba32F:
    w = int(img.rgba32f.width); h = int(img.rgba32f.height)
    chNames = @["A", "B", "G", "R"]
    const comp = [3, 2, 1, 0]
    raw = newSeq[uint8](w*h*16)
    for i, p in img.rgba32f.pixels:
      for c in 0..3:
        let u = cast[uint32](p.data[comp[c]])
        raw[16*i+4*c]=uint8(u and 0xFF); raw[16*i+4*c+1]=uint8((u shr 8) and 0xFF)
        raw[16*i+4*c+2]=uint8((u shr 16) and 0xFF); raw[16*i+4*c+3]=uint8((u shr 24) and 0xFF)
  of dkLuma32F:
    w = int(img.luma32f.width); h = int(img.luma32f.height)
    chNames = @["Y"]
    raw = newSeq[uint8](w*h*4)
    for i, p in img.luma32f.pixels:
      let u = cast[uint32](p.data[0])
      raw[4*i]=uint8(u and 0xFF); raw[4*i+1]=uint8((u shr 8) and 0xFF)
      raw[4*i+2]=uint8((u shr 16) and 0xFF); raw[4*i+3]=uint8((u shr 24) and 0xFF)
  else:
    return err[seq[uint8]](unsupportedError(ukColor, "exr: encode this variant first"))
  if w == 0 or h == 0:
    return err[seq[uint8]](paramError(pkDimensionMismatch, "exr: empty"))
  var output = @ExrMagic
  putU32le(output, 2)
  # chlist
  var chl: seq[uint8] = @[]
  for n in chNames:
    for c in n: chl.add(uint8(c))
    chl.add(0)
    putU32le(chl, 2) # float
    chl.add(0) # pLinear
    chl.add([0'u8, 0, 0]) # reserved
    putU32le(chl, 1); putU32le(chl, 1) # sampling
  chl.add(0) # terminator
  putAttr(output, "channels", "chlist", chl)
  putAttr(output, "compression", "compression", @[uint8(compression)])
  var bw: seq[uint8] = @[]
  putBox(bw, 0, 0, int32(w-1), int32(h-1))
  putAttr(output, "dataWindow", "box2i", bw)
  putAttr(output, "displayWindow", "box2i", bw)
  putAttr(output, "lineOrder", "lineOrder", @[0'u8])
  var par: seq[uint8] = @[]
  let pa = cast[uint32](1.0'f32)
  par.add([uint8(pa and 0xFF), uint8((pa shr 8) and 0xFF),
    uint8((pa shr 16) and 0xFF), uint8((pa shr 24) and 0xFF)])
  putAttr(output, "pixelAspectRatio", "float", par)
  putAttr(output, "screenWindowCenter", "v2f", @[0'u8,0,0,0, 0,0,0,0])
  putAttr(output, "screenWindowWidth", "float", @[0'u8,0,0,0])
  output.add(0) # end of header
  # chunks: ZIP/PXR24 = 16 rows, DWAB = 256 rows, rest lossy = 32 rows
  let rowsPer = if compression == 3 or compression == 5: 16
    elif compression == 9: 256 else: 32
  let lineBytes = w * chNames.len * 4
  let nChunks = (h + rowsPer - 1) div rowsPer
  # offset table placeholder
  let tabOff = output.len
  for _ in 0..<nChunks:
    for _ in 0..7: output.add(0)
  var chunkData: seq[seq[uint8]] = @[]
  var ptypesEnc = newSeq[int32](chNames.len)
  var cbytesEnc = newSeq[int](chNames.len)
  var pLinEnc = newSeq[bool](chNames.len)
  for i in 0..<chNames.len:
    ptypesEnc[i] = 2
    cbytesEnc[i] = 4
    pLinEnc[i] = false
  for ci in 0..<nChunks:
    let y0 = ci * rowsPer
    let rows = min(rowsPer, h - y0)
    let blk = raw[y0*lineBytes..<y0*lineBytes+rows*lineBytes]
    # Disk layout is planar-per-scanline; the transforms run on planar.
    let planar = chunkyToPlanar(blk, w, rows, cbytesEnc)
    var payload: seq[uint8]
    if compression == 5:
      let t = pxr24Apply(blk, w, rows, cbytesEnc, ptypesEnc)
      let cr = deflateZlib(t, 6)
      if not cr.ok: return err[seq[uint8]](cr.err)
      # internal_pxr24.c: store packed (planar) when deflate grows it.
      payload = if cr.value.len <= planar.len: cr.value else: planar
    elif compression == 6 or compression == 7:
      # B44/B44A: float channels ride along uncompressed (spec); half
      # channels would pack here. Reference stores planar when packing
      # grows the chunk (`>=`).
      let t = b44ApplyChunk(planar, w, rows, cbytesEnc, ptypesEnc, pLinEnc,
        compression == 7)
      payload = if t.len < planar.len: t else: planar
    elif compression == 4:
      # PIZ: wavelet + Huffman; raw planar fallback when it does not win
      # (mirrors the nOut < packedbytes gate in internal_exr_apply_piz).
      let (pok, t) = pizApplyChunk(planar, w, rows, cbytesEnc, ptypesEnc)
      if not pok: return err[seq[uint8]](encodingError("exr: piz failed"))
      payload = if t.len < planar.len: t else: planar
    elif compression == 8 or compression == 9:
      # DWAA/DWAB: lossy DCT + quantize at the default level 45.0 (the
      # reference omits dwaCompressionLevel at default); raw planar
      # fallback when the encoding does not win (nWritten >= packed).
      var ech: seq[ExrChannel] = @[]
      for i, n in chNames:
        ech.add(ExrChannel(name: n, pixelType: 2, pLinear: false,
          xSamp: 1, ySamp: 1))
      let (dok, t) = dwaApplyChunk(planar, w, rows, ech, cbytesEnc)
      if not dok: return err[seq[uint8]](encodingError("exr: dwa failed"))
      payload = if t.len < planar.len: t else: planar
    else:
      var tb = planar
      separateHalves(tb)
      samplesToDifferences(tb)
      let cr = deflateZlib(tb, 6)
      if not cr.ok: return err[seq[uint8]](cr.err)
      # internal_zip.c: store planar raw when deflate grows it (`>=`).
      payload = if cr.value.len < planar.len: cr.value else: planar
    var ch: seq[uint8] = @[]
    putU32le(ch, uint32(y0))
    putU32le(ch, uint32(payload.len))
    for b in payload: ch.add(b)
    chunkData.add(ch)
  var doff = output.len
  for i, ch in chunkData:
    for b in 0..7:
      output[tabOff+i*8+b] = uint8((uint64(doff) shr (8*b)) and 0xFF)
    for b in ch: output.add(b)
    doff += ch.len
  ok(output)
