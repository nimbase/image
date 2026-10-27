## VP8 lossy (baseline/keyframe) decoder, pure Nim.
## Port of references/image-webp src/vp8.rs (+ vp8_arithmetic_decoder.rs,
## loop_filter.rs, transform.rs, yuv.rs fancy path) at v0.2.4, which itself
## follows RFC 6386 and libwebp (see references/libwebp).
## Scope: still keyframes only. Interframes, animation and ALPH compositing
## stay `Unsupported` at the container layer (vp8l.nim).
## Error model: corrupt input raises Vp8DecodeError internally, converted to
## `ImageResult.err` at decodeVp8Frame. Never panics on truncated input:
## the bit reader returns defaults past EOF and each section checks.
import std/bitops
import ./vp8tables
import ../error

type
  Vp8DecodeError* = object of CatchableError

proc vp8err(msg: string): ref Vp8DecodeError =
  (ref Vp8DecodeError)(msg: msg)

# ---------- prediction mode enums (RFC 6386 prediction modes) ----------

type
  LumaMode = enum
    lmDc = 0, lmV = 1, lmH = 2, lmTm = 3, lmB = 4
  ChromaMode = enum
    cmDc = 0, cmV = 1, cmH = 2, cmTm = 3
  IntraMode = enum
    imDc = 0, imTm = 1, imVe = 2, imHe = 3, imLd = 4,
    imRd = 5, imVr = 6, imVl = 7, imHd = 8, imHu = 9

func lumaFromI8(v: int8): tuple[ok: bool, m: LumaMode] =
  case v
  of 0: (true, lmDc)
  of 1: (true, lmV)
  of 2: (true, lmH)
  of 3: (true, lmTm)
  of 4: (true, lmB)
  else: (false, lmDc)

func chromaFromI8(v: int8): tuple[ok: bool, m: ChromaMode] =
  case v
  of 0: (true, cmDc)
  of 1: (true, cmV)
  of 2: (true, cmH)
  of 3: (true, cmTm)
  else: (false, cmDc)

func intraFromI8(v: int8): tuple[ok: bool, m: IntraMode] =
  case v
  of 0: (true, imDc)
  of 1: (true, imTm)
  of 2: (true, imVe)
  of 3: (true, imHe)
  of 4: (true, imLd)
  of 5: (true, imRd)
  of 6: (true, imVr)
  of 7: (true, imVl)
  of 8: (true, imHd)
  of 9: (true, imHu)
  else: (false, imDc)

func lumaIntoIntra(m: LumaMode): tuple[ok: bool, m: IntraMode] =
  case m
  of lmDc: (true, imDc)
  of lmV: (true, imVe)
  of lmH: (true, imHe)
  of lmTm: (true, imTm)
  of lmB: (false, imDc)

# ---------- boolean arithmetic decoder (vp8_arithmetic_decoder.rs) ----------
#
# The Rust decoder reads 4-byte big-endian chunks with a fast path plus a
# final-bytes tail (allowing one zero byte past the end). Loading one byte
# at a time is exactly equivalent (shifts accumulate identically) and much
# simpler, so the fast/slow split is not ported: past EOF reads return
# defaults and each section raises via checkEof, mirroring BitResult+check.

type
  BoolDec = object
    data: seq[uint8]
    pos: int
    value: uint64
    range: uint32
    bitCount: int32
    freeLeft: int
    pastEof: bool

proc initBoolDec(data: seq[uint8]): BoolDec =
  BoolDec(data: data, pos: 0, value: 0, range: 255, bitCount: -8,
    freeLeft: 1, pastEof: false)

proc refill(d: var BoolDec) =
  while d.bitCount < 0 and not d.pastEof:
    if d.pos < d.data.len:
      d.value = (d.value shl 8) or uint64(d.data[d.pos])
      inc(d.pos)
      d.bitCount += 8
    elif d.freeLeft > 0:
      dec(d.freeLeft)
      d.value = d.value shl 8
      d.bitCount += 8
    else:
      d.pastEof = true

proc readBit(d: var BoolDec, prob: uint8): bool =
  refill(d)
  if d.pastEof: return false
  let split = 1'u32 + (((d.range - 1) * uint32(prob)) shr 8)
  let bigsplit = uint64(split) shl d.bitCount
  result =
    if d.value >= bigsplit:
      d.range -= split
      d.value -= bigsplit
      true
    else:
      d.range = split
      false
  let shift = countLeadingZeroBits(d.range) - 24
  if shift > 0:
    d.range = d.range shl shift
    d.bitCount -= int32(shift)

proc readFlag(d: var BoolDec): bool =
  readBit(d, 128)

proc readLiteral(d: var BoolDec, n: int): uint8 =
  var v = 0'u8
  for _ in 0..<n:
    v = (v shl 1) or (if readFlag(d): 1'u8 else: 0'u8)
  v

proc readOptionalSigned(d: var BoolDec, n: int): int32 =
  if not readFlag(d): return 0
  let mag = readLiteral(d, n)
  if readFlag(d): -int32(mag) else: int32(mag)

# ---------- tree decoding (tree_nodes_from + read_with_tree) ----------

type
  TreeNode = object
    left, right, prob, index: uint8

func prepareBranch(t: int8): uint8 =
  if t > 0: uint8(t) div 2
  else: 0x80'u8 or uint8(-t)

func valueFromBranch(t: uint8): int8 =
  int8(t and 0x7F'u8)

proc buildNodes(tree: openArray[int8], probs: openArray[uint8]): seq[TreeNode] =
  assert(tree.len == 2 * probs.len)
  result = newSeq[TreeNode](probs.len)
  for i in 0..<probs.len:
    result[i] = TreeNode(left: prepareBranch(tree[2 * i]),
      right: prepareBranch(tree[2 * i + 1]), prob: probs[i], index: uint8(i))

proc readWithTree(d: var BoolDec, tree: openArray[TreeNode],
    startIdx: int): int8 =
  var index = startIdx
  while true:
    let node = tree[index]
    let b = readBit(d, node.prob)
    let t = if b: node.right else: node.left
    if int(t) < tree.len:
      index = int(t)
    else:
      return valueFromBranch(t)

proc checkEof(d: BoolDec) =
  if d.pastEof:
    raise vp8err("webp: truncated VP8 bitstream")

# ---------- 4x4 transforms (transform.rs) ----------

const
  IdctConst1 = 20091'i64
  IdctConst2 = 35468'i64

proc idct4x4(blk: var array[16, int32]) =
  for i in 0..<4:
    let a1 = int64(blk[i]) + int64(blk[8 + i])
    let b1 = int64(blk[i]) - int64(blk[8 + i])
    let t1 = (int64(blk[4 + i]) * IdctConst2) shr 16
    let t2 = int64(blk[12 + i]) + ((int64(blk[12 + i]) * IdctConst1) shr 16)
    let c1 = t1 - t2
    let t1b = int64(blk[4 + i]) + ((int64(blk[4 + i]) * IdctConst1) shr 16)
    let t2b = (int64(blk[12 + i]) * IdctConst2) shr 16
    let d1 = t1b + t2b
    blk[i] = int32(a1 + d1)
    blk[4 + i] = int32(b1 + c1)
    blk[12 + i] = int32(a1 - d1)
    blk[8 + i] = int32(b1 - c1)
  for i in 0..<4:
    let a1 = int64(blk[4 * i]) + int64(blk[4 * i + 2])
    let b1 = int64(blk[4 * i]) - int64(blk[4 * i + 2])
    let t1 = (int64(blk[4 * i + 1]) * IdctConst2) shr 16
    let t2 = int64(blk[4 * i + 3]) +
      ((int64(blk[4 * i + 3]) * IdctConst1) shr 16)
    let c1 = t1 - t2
    let t1b = int64(blk[4 * i + 1]) +
      ((int64(blk[4 * i + 1]) * IdctConst1) shr 16)
    let t2b = (int64(blk[4 * i + 3]) * IdctConst2) shr 16
    let d1 = t1b + t2b
    blk[4 * i] = int32((a1 + d1 + 4) shr 3)
    blk[4 * i + 3] = int32((a1 - d1 + 4) shr 3)
    blk[4 * i + 1] = int32((b1 + c1 + 4) shr 3)
    blk[4 * i + 2] = int32((b1 - c1 + 4) shr 3)

proc iwht4x4(blk: var array[16, int32]) =
  for i in 0..<4:
    let a1 = blk[i] + blk[12 + i]
    let b1 = blk[4 + i] + blk[8 + i]
    let c1 = blk[4 + i] - blk[8 + i]
    let d1 = blk[i] - blk[12 + i]
    blk[i] = a1 + b1
    blk[4 + i] = c1 + d1
    blk[8 + i] = a1 - b1
    blk[12 + i] = d1 - c1
  for i in 0..<4:
    let a1 = blk[4 * i] + blk[4 * i + 3]
    let b1 = blk[4 * i + 1] + blk[4 * i + 2]
    let c1 = blk[4 * i + 1] - blk[4 * i + 2]
    let d1 = blk[4 * i] - blk[4 * i + 3]
    let a2 = a1 + b1
    let b2 = c1 + d1
    let c2 = a1 - b1
    let d2 = d1 - c1
    blk[4 * i] = (a2 + 3) shr 3
    blk[4 * i + 1] = (b2 + 3) shr 3
    blk[4 * i + 2] = (c2 + 3) shr 3
    blk[4 * i + 3] = (d2 + 3) shr 3

# ---------- loop filter (loop_filter.rs) ----------

func lfClamp(v: int32): int32 =
  if v < -128: -128 elif v > 127: 127 else: v

func lfU2s(v: uint8): int32 = int32(v) - 128
func lfS2u(v: int32): uint8 = uint8(lfClamp(v) + 128)
func lfDiff(a, b: uint8): uint8 =
  if a > b: a - b else: b - a

proc lfAdjustV(useOuter: bool, px: var seq[uint8], point, stride: int): int32 =
  let p1 = lfU2s(px[point - 2 * stride])
  let p0 = lfU2s(px[point - stride])
  let q0 = lfU2s(px[point])
  let q1 = lfU2s(px[point + stride])
  let outer = if useOuter: lfClamp(p1 - q1) else: 0
  let a = lfClamp(outer + 3 * (q0 - p0))
  let b = lfClamp(a + 3) shr 3
  let av = lfClamp(a + 4) shr 3
  px[point] = lfS2u(q0 - av)
  px[point - stride] = lfS2u(p0 + b)
  av

proc lfAdjustH(useOuter: bool, px: var seq[uint8], base: int): int32 =
  let p1 = lfU2s(px[base + 2])
  let p0 = lfU2s(px[base + 3])
  let q0 = lfU2s(px[base + 4])
  let q1 = lfU2s(px[base + 5])
  let outer = if useOuter: lfClamp(p1 - q1) else: 0
  let a = lfClamp(outer + 3 * (q0 - p0))
  let b = lfClamp(a + 3) shr 3
  let av = lfClamp(a + 4) shr 3
  px[base + 4] = lfS2u(q0 - av)
  px[base + 3] = lfS2u(p0 + b)
  av

func lfSimpleThreshV(limit: int32, px: seq[uint8], point, stride: int): bool =
  int32(lfDiff(px[point - stride], px[point])) * 2 +
    int32(lfDiff(px[point - 2 * stride], px[point + stride])) div 2 <= limit

func lfSimpleThreshH(limit: int32, px: seq[uint8], base: int): bool =
  int32(lfDiff(px[base + 3], px[base + 4])) * 2 +
    int32(lfDiff(px[base + 2], px[base + 5])) div 2 <= limit

func lfShouldFilterV(interior, edge: uint8, px: seq[uint8],
    point, stride: int): bool =
  lfSimpleThreshV(int32(edge), px, point, stride) and
    lfDiff(px[point - 4 * stride], px[point - 3 * stride]) <= interior and
    lfDiff(px[point - 3 * stride], px[point - 2 * stride]) <= interior and
    lfDiff(px[point - 2 * stride], px[point - stride]) <= interior and
    lfDiff(px[point + 3 * stride], px[point + 2 * stride]) <= interior and
    lfDiff(px[point + 2 * stride], px[point + stride]) <= interior and
    lfDiff(px[point + stride], px[point]) <= interior

func lfShouldFilterH(interior, edge: uint8, px: seq[uint8], base: int): bool =
  lfSimpleThreshH(int32(edge), px, base) and
    lfDiff(px[base], px[base + 1]) <= interior and
    lfDiff(px[base + 1], px[base + 2]) <= interior and
    lfDiff(px[base + 2], px[base + 3]) <= interior and
    lfDiff(px[base + 7], px[base + 6]) <= interior and
    lfDiff(px[base + 6], px[base + 5]) <= interior and
    lfDiff(px[base + 5], px[base + 4]) <= interior

func lfHevV(thresh: uint8, px: seq[uint8], point, stride: int): bool =
  lfDiff(px[point - 2 * stride], px[point - stride]) > thresh or
    lfDiff(px[point + stride], px[point]) > thresh

func lfHevH(thresh: uint8, px: seq[uint8], base: int): bool =
  lfDiff(px[base + 2], px[base + 3]) > thresh or
    lfDiff(px[base + 5], px[base + 4]) > thresh

proc simpleSegmentV(edge: uint8, px: var seq[uint8], point, stride: int) =
  if lfSimpleThreshV(int32(edge), px, point, stride):
    discard lfAdjustV(true, px, point, stride)

proc simpleSegmentH(edge: uint8, px: var seq[uint8], base: int) =
  if lfSimpleThreshH(int32(edge), px, base):
    discard lfAdjustH(true, px, base)

proc subblockFilterV(hevThresh, interior, edge: uint8, px: var seq[uint8],
    point, stride: int) =
  if lfShouldFilterV(interior, edge, px, point, stride):
    let hv = lfHevV(hevThresh, px, point, stride)
    let a = (lfAdjustV(hv, px, point, stride) + 1) shr 1
    if not hv:
      px[point + stride] = lfS2u(lfU2s(px[point + stride]) - a)
      px[point - 2 * stride] = lfS2u(lfU2s(px[point - 2 * stride]) + a)

proc subblockFilterH(hevThresh, interior, edge: uint8, px: var seq[uint8],
    base: int) =
  if lfShouldFilterH(interior, edge, px, base):
    let hv = lfHevH(hevThresh, px, base)
    let a = (lfAdjustH(hv, px, base) + 1) shr 1
    if not hv:
      px[base + 5] = lfS2u(lfU2s(px[base + 5]) - a)
      px[base + 2] = lfS2u(lfU2s(px[base + 2]) + a)

proc macroblockFilterV(hevThresh, interior, edge: uint8, px: var seq[uint8],
    point, stride: int) =
  if lfShouldFilterV(interior, edge, px, point, stride):
    if not lfHevV(hevThresh, px, point, stride):
      let p2 = lfU2s(px[point - 3 * stride])
      let p1 = lfU2s(px[point - 2 * stride])
      let p0 = lfU2s(px[point - stride])
      let q0 = lfU2s(px[point])
      let q1 = lfU2s(px[point + stride])
      let q2 = lfU2s(px[point + 2 * stride])
      let w = lfClamp(lfClamp(p1 - q1) + 3 * (q0 - p0))
      var a = lfClamp((27 * w + 63) shr 7)
      px[point] = lfS2u(q0 - a)
      px[point - stride] = lfS2u(p0 + a)
      a = lfClamp((18 * w + 63) shr 7)
      px[point + stride] = lfS2u(q1 - a)
      px[point - 2 * stride] = lfS2u(p1 + a)
      a = lfClamp((9 * w + 63) shr 7)
      px[point + 2 * stride] = lfS2u(q2 - a)
      px[point - 3 * stride] = lfS2u(p2 + a)
    else:
      discard lfAdjustV(true, px, point, stride)

proc macroblockFilterH(hevThresh, interior, edge: uint8, px: var seq[uint8],
    base: int) =
  if lfShouldFilterH(interior, edge, px, base):
    if not lfHevH(hevThresh, px, base):
      let p2 = lfU2s(px[base + 1])
      let p1 = lfU2s(px[base + 2])
      let p0 = lfU2s(px[base + 3])
      let q0 = lfU2s(px[base + 4])
      let q1 = lfU2s(px[base + 5])
      let q2 = lfU2s(px[base + 6])
      let w = lfClamp(lfClamp(p1 - q1) + 3 * (q0 - p0))
      var a = lfClamp((27 * w + 63) shr 7)
      px[base + 4] = lfS2u(q0 - a)
      px[base + 3] = lfS2u(p0 + a)
      a = lfClamp((18 * w + 63) shr 7)
      px[base + 5] = lfS2u(q1 - a)
      px[base + 2] = lfS2u(p1 + a)
      a = lfClamp((9 * w + 63) shr 7)
      px[base + 6] = lfS2u(q2 - a)
      px[base + 1] = lfS2u(p2 + a)
    else:
      discard lfAdjustH(true, px, base)

# ---------- YUV -> RGB, fancy upsampling (yuv.rs, Bilinear default) ----------

func yuvMulhi*(v: uint8, coeff: uint16): int32 =
  int32((uint32(v) * uint32(coeff)) shr 8)

func yuvClip*(v: int32): uint8 =
  uint8(max(0, min(255, v shr 6)))

func yuvToR*(y, v: uint8): uint8 =
  yuvClip(yuvMulhi(y, 19077) + yuvMulhi(v, 26149) - 14234)

func yuvToG*(y, u, v: uint8): uint8 =
  yuvClip(yuvMulhi(y, 19077) - yuvMulhi(u, 6419) - yuvMulhi(v, 13320) + 8708)

func yuvToB*(y, u: uint8): uint8 =
  yuvClip(yuvMulhi(y, 19077) + yuvMulhi(u, 33050) - 17685)

func fancyChroma*(main, sec1, sec2, tert: uint8): uint8 =
  uint8((9 * uint16(main) + 3 * uint16(sec1) + 3 * uint16(sec2) +
    uint16(tert) + 8) div 16)

proc setPxU8(buf: var seq[uint8], pos: int, y, u, v: uint8) =
  buf[pos] = yuvToR(y, v)
  buf[pos + 1] = yuvToG(y, u, v)
  buf[pos + 2] = yuvToB(y, u)

proc fillRowFancy2(row: var seq[uint8], yRow, u1, u2, v1, v2: seq[uint8]) =
  ## Two-UV-row fancy interpolation over one output row (row.len = yRow.len*3).
  setPxU8(row, 0, yRow[0], fancyChroma(u1[0], u1[0], u2[0], u2[0]),
    fancyChroma(v1[0], v1[0], v2[0], v2[0]))
  var pi = 1
  var k = 0
  while pi + 1 < yRow.len and k + 1 < u1.len:
    setPxU8(row, pi * 3, yRow[pi],
      fancyChroma(u1[k], u1[k + 1], u2[k], u2[k + 1]),
      fancyChroma(v1[k], v1[k + 1], v2[k], v2[k + 1]))
    setPxU8(row, (pi + 1) * 3, yRow[pi + 1],
      fancyChroma(u1[k + 1], u1[k], u2[k + 1], u2[k]),
      fancyChroma(v1[k + 1], v1[k], v2[k + 1], v2[k]))
    pi += 2
    inc(k)
  if pi < yRow.len:
    setPxU8(row, pi * 3, yRow[pi],
      fancyChroma(u1[^1], u1[^1], u2[^1], u2[^1]),
      fancyChroma(v1[^1], v1[^1], v2[^1], v2[^1]))

proc fillRowFancy1(row: var seq[uint8], yRow, uRow, vRow: seq[uint8]) =
  ## Single-UV-row fancy interpolation (top/bottom edge rows).
  setPxU8(row, 0, yRow[0], uRow[0], vRow[0])
  var pi = 1
  var k = 0
  while pi + 1 < yRow.len and k + 1 < uRow.len:
    setPxU8(row, pi * 3, yRow[pi],
      fancyChroma(uRow[k], uRow[k + 1], uRow[k], uRow[k + 1]),
      fancyChroma(vRow[k], vRow[k + 1], vRow[k], vRow[k + 1]))
    setPxU8(row, (pi + 1) * 3, yRow[pi + 1],
      fancyChroma(uRow[k + 1], uRow[k], uRow[k + 1], uRow[k]),
      fancyChroma(vRow[k + 1], vRow[k], vRow[k + 1], vRow[k]))
    pi += 2
    inc(k)
  if pi < yRow.len:
    setPxU8(row, pi * 3, yRow[pi], uRow[^1], vRow[^1])

proc fillRgbFancy(buf: var seq[uint8], yBuf, uBuf, vBuf: seq[uint8],
    width, height, bufWidth: int) =
  ## buf.len = width*height*3; chroma rows padded to bufWidth div 2.
  let chromaBufW = bufWidth div 2
  let chromaW = (width + 1) div 2
  var topRow = newSeq[uint8](width * 3)
  fillRowFancy1(topRow, yBuf[0..<width], uBuf[0..<chromaW], vBuf[0..<chromaW])
  for i in 0..<topRow.len: buf[i] = topRow[i]
  var outPos = width * 3
  var yPos = bufWidth
  var cPos = 0
  while outPos + 2 * width * 3 <= buf.len and
      yPos + 2 * bufWidth <= height * bufWidth:
    let u1 = uBuf[cPos..<cPos + chromaBufW]
    let u2 = uBuf[cPos + chromaBufW..<cPos + 2 * chromaBufW]
    let v1 = vBuf[cPos..<cPos + chromaBufW]
    let v2 = vBuf[cPos + chromaBufW..<cPos + 2 * chromaBufW]
    var row1 = newSeq[uint8](width * 3)
    var row2 = newSeq[uint8](width * 3)
    fillRowFancy2(row1, yBuf[yPos..<yPos + width], u1[0..<chromaW],
      u2[0..<chromaW], v1[0..<chromaW], v2[0..<chromaW])
    fillRowFancy2(row2, yBuf[yPos + bufWidth..<yPos + bufWidth + width],
      u2[0..<chromaW], u1[0..<chromaW], v2[0..<chromaW], v1[0..<chromaW])
    for i in 0..<row1.len:
      buf[outPos + i] = row1[i]
      buf[outPos + width * 3 + i] = row2[i]
    outPos += 2 * width * 3
    yPos += 2 * bufWidth
    cPos += chromaBufW
  if outPos < buf.len:
    let chromaH = (height + 1) div 2
    let startC = (chromaH - 1) * chromaBufW
    var rowL = newSeq[uint8](width * 3)
    fillRowFancy1(rowL, yBuf[yPos..<yPos + width],
      uBuf[startC..<startC + chromaW], vBuf[startC..<startC + chromaW])
    for i in 0..<rowL.len: buf[outPos + i] = rowL[i]

# ---------- intra prediction (Section 12, RFC 6386) ----------

func avg3(l, t, r: uint8): uint8 =
  uint8((uint16(l) + 2 * uint16(t) + uint16(r) + 2) shr 2)

func avg2(t, r: uint8): uint8 =
  uint8((uint16(t) + uint16(r) + 1) shr 1)

proc addResidue(pblock: var seq[uint8], rblock: array[16, int32],
    y0, x0, stride: int) =
  var pos = y0 * stride + x0
  for r in 0..<4:
    for c in 0..<4:
      pblock[pos + c] = uint8(max(0, min(255, rblock[r * 4 + c] +
        int32(pblock[pos + c]))))
    pos += stride

proc predictVpred(a: var seq[uint8], size, x0, y0, stride: int) =
  let aboveLen = y0 * stride - x0
  let n = min(stride - 1, aboveLen)
  for r in 0..<size:
    for c in 0..<n:
      a[(y0 + r) * stride + 1 + c] = a[(y0 - 1) * stride + x0 + c]

proc predictHpred(a: var seq[uint8], size, x0, y0, stride: int) =
  for r in 0..<size:
    let left = a[(y0 + r) * stride + x0 - 1]
    for c in x0..<stride:
      a[(y0 + r) * stride + c] = left

proc predictDcpred(a: var seq[uint8], size, stride: int, above, left: bool) =
  var sum = 0'u32
  var shf = if size == 8: 2 else: 3
  if left:
    for y in 0..<size:
      sum += uint32(a[(y + 1) * stride])
    shf += 1
  if above:
    for x in 1..size:
      sum += uint32(a[x])
    shf += 1
  let dcval =
    if not left and not above: 128'u32
    else: (sum + (1'u32 shl (shf - 1))) shr shf
  for y in 0..<size:
    for x in 0..<size:
      a[1 + stride * (y + 1) + x] = uint8(dcval)

proc predictTmpred(a: var seq[uint8], size, x0, y0, stride: int) =
  let p = int32(a[(y0 - 1) * stride + x0 - 1])
  for y in 0..<size:
    let lm = int32(a[(y0 + y) * stride + x0 - 1]) - p
    for j in 0..<size:
      a[(y0 + y) * stride + x0 + j] =
        uint8(max(0, min(255, lm + int32(a[(y0 - 1) * stride + x0 + j]))))

proc predictBdcpred(a: var seq[uint8], x0, y0, stride: int) =
  var v = 4'u32
  for i in 0..<4:
    v += uint32(a[(y0 - 1) * stride + x0 + i])
  for i in 0..<4:
    v += uint32(a[(y0 + i) * stride + x0 - 1])
  v = v shr 3
  for r in 0..<4:
    for c in 0..<4:
      a[(y0 + r) * stride + x0 + c] = uint8(v)

func topleftPx(a: seq[uint8], x0, y0, stride: int): uint8 =
  a[(y0 - 1) * stride + x0 - 1]

proc topPx(a: seq[uint8], x0, y0, stride: int): array[8, uint8] =
  let pos = (y0 - 1) * stride + x0
  for i in 0..<8: result[i] = a[pos + i]

proc leftPx(a: seq[uint8], x0, y0, stride: int): array[4, uint8] =
  [a[y0 * stride + x0 - 1], a[(y0 + 1) * stride + x0 - 1],
    a[(y0 + 2) * stride + x0 - 1], a[(y0 + 3) * stride + x0 - 1]]

proc edgePx(a: seq[uint8], x0, y0, stride: int): array[9, uint8] =
  let pos = (y0 - 1) * stride + x0 - 1
  result[0] = a[pos + 4 * stride]
  result[1] = a[pos + 3 * stride]
  result[2] = a[pos + 2 * stride]
  result[3] = a[pos + stride]
  for i in 0..<5: result[4 + i] = a[pos + i]

proc predictBvepred(a: var seq[uint8], x0, y0, stride: int) =
  let p = topleftPx(a, x0, y0, stride)
  let t = topPx(a, x0, y0, stride)
  let avgs = [avg3(p, t[0], t[1]), avg3(t[0], t[1], t[2]),
    avg3(t[1], t[2], t[3]), avg3(t[2], t[3], t[4])]
  var pos = y0 * stride + x0
  for _ in 0..<4:
    for c in 0..<4: a[pos + c] = avgs[c]
    pos += stride

proc predictBhepred(a: var seq[uint8], x0, y0, stride: int) =
  let p = topleftPx(a, x0, y0, stride)
  let l = leftPx(a, x0, y0, stride)
  let avgs = [avg3(p, l[0], l[1]), avg3(l[0], l[1], l[2]),
    avg3(l[1], l[2], l[3]), avg3(l[2], l[3], l[3])]
  var pos = y0 * stride + x0
  for r in 0..<4:
    for c in 0..<4: a[pos + c] = avgs[r]
    pos += stride

proc predictBldpred(a: var seq[uint8], x0, y0, stride: int) =
  let t = topPx(a, x0, y0, stride)
  let avgs = [avg3(t[0], t[1], t[2]), avg3(t[1], t[2], t[3]),
    avg3(t[2], t[3], t[4]), avg3(t[3], t[4], t[5]), avg3(t[4], t[5], t[6]),
    avg3(t[5], t[6], t[7]), avg3(t[6], t[7], t[7])]
  var pos = y0 * stride + x0
  for i in 0..<4:
    for c in 0..<4: a[pos + c] = avgs[i + c]
    pos += stride

proc predictBrdpred(a: var seq[uint8], x0, y0, stride: int) =
  let e = edgePx(a, x0, y0, stride)
  let avgs = [avg3(e[0], e[1], e[2]), avg3(e[1], e[2], e[3]),
    avg3(e[2], e[3], e[4]), avg3(e[3], e[4], e[5]), avg3(e[4], e[5], e[6]),
    avg3(e[5], e[6], e[7]), avg3(e[6], e[7], e[8])]
  var pos = y0 * stride + x0
  for i in 0..<4:
    for c in 0..<4: a[pos + c] = avgs[3 - i + c]
    pos += stride

proc predictBvrpred(a: var seq[uint8], x0, y0, stride: int) =
  let e = edgePx(a, x0, y0, stride)
  a[(y0 + 3) * stride + x0] = avg3(e[1], e[2], e[3])
  a[(y0 + 2) * stride + x0] = avg3(e[2], e[3], e[4])
  a[(y0 + 3) * stride + x0 + 1] = avg3(e[3], e[4], e[5])
  a[(y0 + 1) * stride + x0] = avg3(e[3], e[4], e[5])
  a[(y0 + 2) * stride + x0 + 1] = avg2(e[4], e[5])
  a[y0 * stride + x0] = avg2(e[4], e[5])
  a[(y0 + 3) * stride + x0 + 2] = avg3(e[4], e[5], e[6])
  a[(y0 + 1) * stride + x0 + 1] = avg3(e[4], e[5], e[6])
  a[(y0 + 2) * stride + x0 + 2] = avg2(e[5], e[6])
  a[y0 * stride + x0 + 1] = avg2(e[5], e[6])
  a[(y0 + 3) * stride + x0 + 3] = avg3(e[5], e[6], e[7])
  a[(y0 + 1) * stride + x0 + 2] = avg3(e[5], e[6], e[7])
  a[(y0 + 2) * stride + x0 + 3] = avg2(e[6], e[7])
  a[y0 * stride + x0 + 2] = avg2(e[6], e[7])
  a[(y0 + 1) * stride + x0 + 3] = avg3(e[6], e[7], e[8])
  a[y0 * stride + x0 + 3] = avg2(e[7], e[8])

proc predictBvlpred(a: var seq[uint8], x0, y0, stride: int) =
  let t = topPx(a, x0, y0, stride)
  a[y0 * stride + x0] = avg2(t[0], t[1])
  a[(y0 + 1) * stride + x0] = avg3(t[0], t[1], t[2])
  a[(y0 + 2) * stride + x0] = avg2(t[1], t[2])
  a[y0 * stride + x0 + 1] = avg2(t[1], t[2])
  a[(y0 + 1) * stride + x0 + 1] = avg3(t[1], t[2], t[3])
  a[(y0 + 3) * stride + x0] = avg3(t[1], t[2], t[3])
  a[(y0 + 2) * stride + x0 + 1] = avg2(t[2], t[3])
  a[y0 * stride + x0 + 2] = avg2(t[2], t[3])
  a[(y0 + 3) * stride + x0 + 1] = avg3(t[2], t[3], t[4])
  a[(y0 + 1) * stride + x0 + 2] = avg3(t[2], t[3], t[4])
  a[(y0 + 2) * stride + x0 + 2] = avg2(t[3], t[4])
  a[y0 * stride + x0 + 3] = avg2(t[3], t[4])
  a[(y0 + 3) * stride + x0 + 2] = avg3(t[3], t[4], t[5])
  a[(y0 + 1) * stride + x0 + 3] = avg3(t[3], t[4], t[5])
  a[(y0 + 2) * stride + x0 + 3] = avg3(t[4], t[5], t[6])
  a[(y0 + 3) * stride + x0 + 3] = avg3(t[5], t[6], t[7])

proc predictBhdpred(a: var seq[uint8], x0, y0, stride: int) =
  let e = edgePx(a, x0, y0, stride)
  a[(y0 + 3) * stride + x0] = avg2(e[0], e[1])
  a[(y0 + 3) * stride + x0 + 1] = avg3(e[0], e[1], e[2])
  a[(y0 + 2) * stride + x0] = avg2(e[1], e[2])
  a[(y0 + 3) * stride + x0 + 2] = avg2(e[1], e[2])
  a[(y0 + 2) * stride + x0 + 1] = avg3(e[1], e[2], e[3])
  a[(y0 + 3) * stride + x0 + 3] = avg3(e[1], e[2], e[3])
  a[(y0 + 2) * stride + x0 + 2] = avg2(e[2], e[3])
  a[(y0 + 1) * stride + x0] = avg2(e[2], e[3])
  a[(y0 + 2) * stride + x0 + 3] = avg3(e[2], e[3], e[4])
  a[(y0 + 1) * stride + x0 + 1] = avg3(e[2], e[3], e[4])
  a[(y0 + 1) * stride + x0 + 2] = avg2(e[3], e[4])
  a[y0 * stride + x0] = avg2(e[3], e[4])
  a[(y0 + 1) * stride + x0 + 3] = avg3(e[3], e[4], e[5])
  a[y0 * stride + x0 + 1] = avg3(e[3], e[4], e[5])
  a[y0 * stride + x0 + 2] = avg3(e[4], e[5], e[6])
  a[y0 * stride + x0 + 3] = avg3(e[5], e[6], e[7])

proc predictBhupred(a: var seq[uint8], x0, y0, stride: int) =
  let l = leftPx(a, x0, y0, stride)
  a[y0 * stride + x0] = avg2(l[0], l[1])
  a[y0 * stride + x0 + 1] = avg3(l[0], l[1], l[2])
  a[y0 * stride + x0 + 2] = avg2(l[1], l[2])
  a[(y0 + 1) * stride + x0] = avg2(l[1], l[2])
  a[y0 * stride + x0 + 3] = avg3(l[1], l[2], l[3])
  a[(y0 + 1) * stride + x0 + 1] = avg3(l[1], l[2], l[3])
  a[(y0 + 1) * stride + x0 + 2] = avg2(l[2], l[3])
  a[(y0 + 2) * stride + x0] = avg2(l[2], l[3])
  a[(y0 + 1) * stride + x0 + 3] = avg3(l[2], l[3], l[3])
  a[(y0 + 2) * stride + x0 + 1] = avg3(l[2], l[3], l[3])
  a[(y0 + 2) * stride + x0 + 2] = l[3]
  a[(y0 + 2) * stride + x0 + 3] = l[3]
  a[(y0 + 3) * stride + x0] = l[3]
  a[(y0 + 3) * stride + x0 + 1] = l[3]
  a[(y0 + 3) * stride + x0 + 2] = l[3]
  a[(y0 + 3) * stride + x0 + 3] = l[3]

proc predict4x4(ws: var seq[uint8], stride: int, modes: array[16, IntraMode],
    resdata: array[384, int32]) =
  for sby in 0..<4:
    for sbx in 0..<4:
      let i = sbx + sby * 4
      let y0 = sby * 4 + 1
      let x0 = sbx * 4 + 1
      case modes[i]
      of imTm: predictTmpred(ws, 4, x0, y0, stride)
      of imVe: predictBvepred(ws, x0, y0, stride)
      of imHe: predictBhepred(ws, x0, y0, stride)
      of imDc: predictBdcpred(ws, x0, y0, stride)
      of imLd: predictBldpred(ws, x0, y0, stride)
      of imRd: predictBrdpred(ws, x0, y0, stride)
      of imVr: predictBvrpred(ws, x0, y0, stride)
      of imVl: predictBvlpred(ws, x0, y0, stride)
      of imHd: predictBhdpred(ws, x0, y0, stride)
      of imHu: predictBhupred(ws, x0, y0, stride)
      var rb: array[16, int32]
      for k in 0..<16: rb[k] = resdata[i * 16 + k]
      addResidue(ws, rb, y0, x0, stride)

proc createBorderLuma(mbx, mby, mbw: int, top, left: seq[uint8]): seq[uint8] =
  let stride = 21
  result = newSeq[uint8](357)
  # above row (1 + 20)
  if mby == 0:
    for i in 1..<stride: result[i] = 127
  else:
    for i in 0..<16: result[1 + i] = top[mbx * 16 + i]
    if mbx == mbw - 1:
      for i in 16..<20: result[1 + i] = top[mbx * 16 + 15]
    else:
      for i in 16..<20: result[1 + i] = top[mbx * 16 + i]
  # rows 4/8/12 cols 17..20 duplicate the above row
  for i in 17..<stride:
    result[4 * stride + i] = result[i]
    result[8 * stride + i] = result[i]
    result[12 * stride + i] = result[i]
  # left column
  if mbx == 0:
    for i in 0..<16: result[(i + 1) * stride] = 129
  else:
    for i in 0..<16: result[(i + 1) * stride] = left[1 + i]
  # top-left corner
  result[0] =
    if mby == 0: 127'u8
    elif mbx == 0: 129'u8
    else: left[0]

proc createBorderChroma(mbx, mby: int, top, left: seq[uint8]): seq[uint8] =
  let stride = 9
  result = newSeq[uint8](81)
  if mby == 0:
    for i in 1..<stride: result[i] = 127
  else:
    for i in 0..<8: result[1 + i] = top[mbx * 8 + i]
  if mbx == 0:
    for y in 0..<8: result[(y + 1) * stride] = 129
  else:
    for y in 0..<8: result[(y + 1) * stride] = left[1 + y]
  result[0] =
    if mby == 0: 127'u8
    elif mbx == 0: 129'u8
    else: left[0]

proc setChromaBorder(leftB, topB: var seq[uint8], cb: seq[uint8],
    mbx: int) =
  let stride = 9
  leftB[0] = cb[8]
  for i in 0..<8: leftB[1 + i] = cb[(i + 1) * stride + 8]
  for i in 0..<8: topB[mbx * 8 + i] = cb[8 * stride + 1 + i]

# ---------- static trees (const probs; built once) ----------

let YmodeNodes = buildNodes(KeyframeYmodeTree, KeyframeYmodeProbs)
let UvNodes = buildNodes(KeyframeUvModeTree, KeyframeUvModeProbs)
let BpredNodes: array[10, array[10, seq[TreeNode]]] = block:
  var o: array[10, array[10, seq[TreeNode]]]
  for i in 0..<10:
    for j in 0..<10:
      o[i][j] = buildNodes(KeyframeBpredModeTree, KeyframeBpredModeProbs[i][j])
  o

# ---------- decoder state ----------

type
  MacroBlock = object
    bpred: array[16, IntraMode]
    complexity: array[9, uint8]
    lumaMode: LumaMode
    chromaMode: ChromaMode
    segmentId: uint8
    coeffsSkipped: bool
    nonZeroDct: bool
  Segment = object
    ydc, yac, y2dc, y2ac, uvdc, uvac: int16
    deltaValues: bool
    quantizerLevel, loopfilterLevel: int8
  Vp8Frame* = object
    width*, height*: int
    ybuf*, ubuf*, vbuf*: seq[uint8]
  Vp8Decoder = object
    data: seq[uint8]
    pos: int
    b: BoolDec
    mbw, mbh: int
    frame: Vp8Frame
    filterSimple: bool
    filterLevel: uint8
    sharpness: uint8
    segmentsEnabled: bool
    segmentsUpdateMap: bool
    segs: array[4, Segment]
    lfAdjustEnabled: bool
    refDelta: array[4, int32]
    modeDelta: array[4, int32]
    partitions: array[8, BoolDec]
    numPartitions: int
    segNodes: seq[TreeNode]
    tokenProbs: array[4, array[8, array[3, seq[TreeNode]]]]
    probSkip: tuple[has: bool, prob: uint8]
    top: seq[MacroBlock]
    left: MacroBlock
    macroblocks: seq[MacroBlock]
    topBorderY, leftBorderY: seq[uint8]
    topBorderU, leftBorderU: seq[uint8]
    topBorderV, leftBorderV: seq[uint8]

proc defaultMacroBlock(): MacroBlock =
  result.bpred = [imDc, imDc, imDc, imDc, imDc, imDc, imDc, imDc,
    imDc, imDc, imDc, imDc, imDc, imDc, imDc, imDc]

proc initVp8Decoder(data: seq[uint8]): Vp8Decoder =
  result.data = data
  for i in 0..<4:
    for j in 0..<8:
      for k in 0..<3:
        result.tokenProbs[i][j][k] = buildNodes(DctTokenTree, CoeffProbs[i][j][k])
  result.segNodes = buildNodes(SegmentIdTree, [255'u8, 255'u8, 255'u8])
  result.left = defaultMacroBlock()

proc readBytes(dec: var Vp8Decoder, n: int): seq[uint8] =
  if n < 0 or dec.pos + n > dec.data.len:
    raise vp8err("webp: truncated VP8 header")
  result = dec.data[dec.pos..<dec.pos + n]
  dec.pos += n

proc readU24(dec: var Vp8Decoder): int =
  let b = dec.readBytes(3)
  int(b[0]) or (int(b[1]) shl 8) or (int(b[2]) shl 16)

proc readU16(dec: var Vp8Decoder): int =
  let b = dec.readBytes(2)
  int(b[0]) or (int(b[1]) shl 8)

# ---------- frame header (Section 9) ----------

proc readSegmentUpdates(dec: var Vp8Decoder) =
  dec.segmentsUpdateMap = dec.b.readFlag()
  let updateFeat = dec.b.readFlag()
  if updateFeat:
    let featMode = dec.b.readFlag()
    for i in 0..<4:
      dec.segs[i].deltaValues = not featMode
    for i in 0..<4:
      dec.segs[i].quantizerLevel = int8(dec.b.readOptionalSigned(7))
    for i in 0..<4:
      dec.segs[i].loopfilterLevel = int8(dec.b.readOptionalSigned(6))
  if dec.segmentsUpdateMap:
    for i in 0..<3:
      let update = dec.b.readFlag()
      dec.segNodes[i].prob = if update: dec.b.readLiteral(8) else: 255
  checkEof(dec.b)

proc readLfAdjustments(dec: var Vp8Decoder) =
  if dec.b.readFlag():
    for i in 0..<4:
      dec.refDelta[i] = dec.b.readOptionalSigned(6)
    for i in 0..<4:
      dec.modeDelta[i] = dec.b.readOptionalSigned(6)
  checkEof(dec.b)

func dcQuant(idx: int): int16 =
  DcQuant[max(0, min(127, idx))]

func acQuant(idx: int): int16 =
  AcQuant[max(0, min(127, idx))]

proc readQuantization(dec: var Vp8Decoder) =
  let yacAbs = dec.b.readLiteral(7)
  let ydcDelta = dec.b.readOptionalSigned(4)
  let y2dcDelta = dec.b.readOptionalSigned(4)
  let y2acDelta = dec.b.readOptionalSigned(4)
  let uvdcDelta = dec.b.readOptionalSigned(4)
  let uvacDelta = dec.b.readOptionalSigned(4)
  let n = if dec.segmentsEnabled: 4 else: 1
  for i in 0..<n:
    let base =
      if dec.segmentsEnabled:
        if dec.segs[i].deltaValues:
          int32(dec.segs[i].quantizerLevel) + int32(yacAbs)
        else:
          int32(dec.segs[i].quantizerLevel)
      else:
        int32(yacAbs)
    dec.segs[i].ydc = dcQuant(int(base + ydcDelta))
    dec.segs[i].yac = acQuant(int(base))
    dec.segs[i].y2dc = dcQuant(int(base + y2dcDelta)) * 2
    dec.segs[i].y2ac = int16((int32(acQuant(int(base + y2acDelta))) * 155) div 100)
    dec.segs[i].uvdc = dcQuant(int(base + uvdcDelta))
    dec.segs[i].uvac = acQuant(int(base + uvacDelta))
    if dec.segs[i].y2ac < 8: dec.segs[i].y2ac = 8
    if dec.segs[i].uvdc > 132: dec.segs[i].uvdc = 132
  checkEof(dec.b)

proc updateTokenProbs(dec: var Vp8Decoder) =
  for i in 0..<4:
    for j in 0..<8:
      for k in 0..<3:
        for t in 0..<11:
          if dec.b.readBit(CoeffUpdateProbs[i][j][k][t]):
            dec.tokenProbs[i][j][k][t].prob = dec.b.readLiteral(8)
  checkEof(dec.b)

proc initPartitions(dec: var Vp8Decoder, n: int) =
  if n > 1:
    let sizes = dec.readBytes(3 * (n - 1))
    for i in 0..<n - 1:
      let sz = int(sizes[3 * i]) or (int(sizes[3 * i + 1]) shl 8) or
        (int(sizes[3 * i + 2]) shl 16)
      dec.partitions[i] = initBoolDec(dec.readBytes(sz))
  dec.partitions[n - 1] = initBoolDec(dec.data[dec.pos..^1])
  dec.pos = dec.data.len

proc readFrameHeader(dec: var Vp8Decoder) =
  let tag = dec.readU24()
  let keyframe = (tag and 1) == 0
  let version = (tag shr 1) and 7
  let forDisplay = ((tag shr 4) and 1) != 0
  let firstSize = tag shr 5
  if keyframe:
    let magic = dec.readBytes(3)
    if magic != @[0x9D'u8, 0x01, 0x2A]:
      raise vp8err("webp: bad VP8 magic")
    let w = dec.readU16()
    let h = dec.readU16()
    dec.frame.width = w and 0x3FFF
    dec.frame.height = h and 0x3FFF
    if dec.frame.width <= 0 or dec.frame.height <= 0 or
        dec.frame.width > 16384 or dec.frame.height > 16384:
      raise vp8err("webp: bad VP8 dimensions")
    dec.mbw = (dec.frame.width + 15) div 16
    dec.mbh = (dec.frame.height + 15) div 16
    dec.frame.ybuf = newSeq[uint8](dec.mbw * 16 * dec.mbh * 16)
    dec.frame.ubuf = newSeq[uint8](dec.mbw * 8 * dec.mbh * 8)
    dec.frame.vbuf = newSeq[uint8](dec.mbw * 8 * dec.mbh * 8)
    var topMb = defaultMacroBlock()
    dec.top = newSeq[MacroBlock](dec.mbw)
    for i in 0..<dec.mbw: dec.top[i] = topMb
    dec.left = defaultMacroBlock()
    dec.topBorderY = newSeq[uint8](dec.frame.width + 4 + 16)
    for i in 0..<dec.topBorderY.len: dec.topBorderY[i] = 127
    dec.leftBorderY = newSeq[uint8](1 + 16)
    for i in 0..<dec.leftBorderY.len: dec.leftBorderY[i] = 129
    dec.topBorderU = newSeq[uint8](8 * dec.mbw)
    for i in 0..<dec.topBorderU.len: dec.topBorderU[i] = 127
    dec.leftBorderU = newSeq[uint8](1 + 8)
    for i in 0..<dec.leftBorderU.len: dec.leftBorderU[i] = 129
    dec.topBorderV = newSeq[uint8](8 * dec.mbw)
    for i in 0..<dec.topBorderV.len: dec.topBorderV[i] = 127
    dec.leftBorderV = newSeq[uint8](1 + 8)
    for i in 0..<dec.leftBorderV.len: dec.leftBorderV[i] = 129
  dec.b = initBoolDec(dec.readBytes(firstSize))
  if keyframe:
    let colorSpace = dec.b.readLiteral(1)
    discard dec.b.readLiteral(1) # pixel type, informational
    if colorSpace != 0:
      raise vp8err("webp: bad VP8 colorspace")
  dec.segmentsEnabled = dec.b.readFlag()
  if dec.segmentsEnabled:
    dec.readSegmentUpdates()
  dec.filterSimple = dec.b.readFlag()
  dec.filterLevel = dec.b.readLiteral(6)
  dec.sharpness = dec.b.readLiteral(3)
  dec.lfAdjustEnabled = dec.b.readFlag()
  if dec.lfAdjustEnabled:
    dec.readLfAdjustments()
  let np = 1 shl int(dec.b.readLiteral(2))
  checkEof(dec.b)
  dec.numPartitions = np
  dec.initPartitions(np)
  dec.readQuantization()
  if not keyframe:
    raise vp8err("webp: VP8 interframes unsupported")
  discard dec.b.readLiteral(1) # refresh entropy probs (unchecked, as upstream)
  dec.updateTokenProbs()
  let mbNoSkip = dec.b.readLiteral(1)
  dec.probSkip =
    if mbNoSkip == 1: (true, dec.b.readLiteral(8))
    else: (false, 0'u8)
  checkEof(dec.b)

# ---------- macroblocks, coefficients, residual ----------

proc readMacroblockHeader(dec: var Vp8Decoder, mbx: int): MacroBlock =
  result = defaultMacroBlock()
  if dec.segmentsEnabled and dec.segmentsUpdateMap:
    result.segmentId = uint8(dec.b.readWithTree(dec.segNodes, 0))
  result.coeffsSkipped =
    if dec.probSkip.has: dec.b.readBit(dec.probSkip.prob)
    else: false
  # still keyframes only: always intra
  let luma = dec.b.readWithTree(YmodeNodes, 0)
  let (lok, lm) = lumaFromI8(luma)
  if not lok:
    raise vp8err("webp: bad VP8 luma mode")
  result.lumaMode = lm
  let (iok, im) = lumaIntoIntra(lm)
  if not iok:
    for y in 0..<4:
      for x in 0..<4:
        let nodes = BpredNodes[ord(dec.top[mbx].bpred[12 + x])][ord(dec.left.bpred[y])]
        let intra = dec.b.readWithTree(nodes, 0)
        let (bok, bm) = intraFromI8(intra)
        if not bok:
          raise vp8err("webp: bad VP8 intra mode")
        result.bpred[x + y * 4] = bm
        dec.top[mbx].bpred[12 + x] = bm
        dec.left.bpred[y] = bm
  else:
    for i in 0..<4:
      result.bpred[12 + i] = im
      dec.left.bpred[i] = im
  let chroma = dec.b.readWithTree(UvNodes, 0)
  let (cok, cm) = chromaFromI8(chroma)
  if not cok:
    raise vp8err("webp: bad VP8 chroma mode")
  result.chromaMode = cm
  dec.top[mbx].chromaMode = cm
  dec.top[mbx].lumaMode = lm
  dec.top[mbx].bpred = result.bpred
  checkEof(dec.b)

proc readCoefficients(dec: var Vp8Decoder, blk: var array[16, int32],
    p, plane, complexity: int, dcq, acq: int16): bool =
  let first = if plane == 0: 1 else: 0
  var cx = complexity
  var hasCoeffs = false
  var skip = false
  for i in first..<16:
    let band = int(CoeffBands[i])
    let tok = dec.partitions[p].readWithTree(dec.tokenProbs[plane][band][cx],
      if skip: 1 else: 0)
    var absVal: int32
    case tok
    of 11: break # DCT_EOB
    of 0: # DCT_0
      skip = true
      hasCoeffs = true
      cx = 0
      continue
    of 1..4:
      absVal = int32(tok)
    of 5..10:
      let ci = int(tok) - 5
      var extra = 0'i16
      for t in ProbDctCat[ci]:
        if t == 0: break
        let bit = dec.partitions[p].readBit(t)
        extra = extra + extra + (if bit: 1'i16 else: 0'i16)
      absVal = int32(DctCatBase[ci]) + int32(extra)
    else:
      raise vp8err("webp: bad VP8 token")
    skip = false
    cx = if absVal == 0: 0 elif absVal == 1: 1 else: 2
    if dec.partitions[p].readFlag():
      absVal = -absVal
    let zz = int(Zigzag[i])
    blk[zz] = absVal * int32(if zz > 0: acq else: dcq)
    hasCoeffs = true
  checkEof(dec.partitions[p])
  hasCoeffs

proc readResidualData(dec: var Vp8Decoder, mb: var MacroBlock, mbx,
    p: int): array[384, int32] =
  let sindex = int(mb.segmentId)
  var plane = if mb.lumaMode == lmB: 3 else: 1
  if plane == 1:
    let cx = int(dec.top[mbx].complexity[0]) + int(dec.left.complexity[0])
    var blk: array[16, int32]
    let n = dec.readCoefficients(blk, p, plane, cx, dec.segs[sindex].y2dc,
      dec.segs[sindex].y2ac)
    dec.left.complexity[0] = if n: 1 else: 0
    dec.top[mbx].complexity[0] = if n: 1 else: 0
    iwht4x4(blk)
    for k in 0..<16: result[16 * k] = blk[k]
    plane = 0
  for y in 0..<4:
    var leftCx = dec.left.complexity[y + 1]
    for x in 0..<4:
      let i = x + y * 4
      var blk: array[16, int32]
      # plane 0 skips position 0 (first=1): the WHT-derived DC already
      # stored in result[i*16] must be preserved (Rust decodes in place).
      blk[0] = result[i * 16]
      let cx = int(dec.top[mbx].complexity[x + 1]) + int(leftCx)
      let n = dec.readCoefficients(blk, p, plane, cx, dec.segs[sindex].ydc,
        dec.segs[sindex].yac)
      if blk[0] != 0 or n:
        mb.nonZeroDct = true
        idct4x4(blk)
      for k in 0..<16: result[i * 16 + k] = blk[k]
      leftCx = if n: 1 else: 0
      dec.top[mbx].complexity[x + 1] = if n: 1 else: 0
    dec.left.complexity[y + 1] = leftCx
  plane = 2
  for j in [5, 7]:
    for y in 0..<2:
      var leftCx = dec.left.complexity[y + j]
      for x in 0..<2:
        let i = x + y * 2 + (if j == 5: 16 else: 20)
        var blk: array[16, int32]
        let cx = int(dec.top[mbx].complexity[x + j]) + int(leftCx)
        let n = dec.readCoefficients(blk, p, plane, cx, dec.segs[sindex].uvdc,
          dec.segs[sindex].uvac)
        if blk[0] != 0 or n:
          mb.nonZeroDct = true
          idct4x4(blk)
        for k in 0..<16: result[i * 16 + k] = blk[k]
        leftCx = if n: 1 else: 0
        dec.top[mbx].complexity[x + j] = if n: 1 else: 0
      dec.left.complexity[y + j] = leftCx

# ---------- prediction into frame planes ----------

proc intraPredictLuma(dec: var Vp8Decoder, mbx, mby: int, mb: MacroBlock,
    resdata: array[384, int32]) =
  let stride = 21
  var ws = createBorderLuma(mbx, mby, dec.mbw, dec.topBorderY, dec.leftBorderY)
  case mb.lumaMode
  of lmV: predictVpred(ws, 16, 1, 1, stride)
  of lmH: predictHpred(ws, 16, 1, 1, stride)
  of lmTm: predictTmpred(ws, 16, 1, 1, stride)
  of lmDc: predictDcpred(ws, 16, stride, mby != 0, mbx != 0)
  of lmB: predict4x4(ws, stride, mb.bpred, resdata)
  if mb.lumaMode != lmB:
    for y in 0..<4:
      for x in 0..<4:
        let i = x + y * 4
        var rb: array[16, int32]
        for k in 0..<16: rb[k] = resdata[i * 16 + k]
        addResidue(ws, rb, 1 + y * 4, 1 + x * 4, stride)
  dec.leftBorderY[0] = ws[16]
  for i in 0..<16:
    dec.leftBorderY[1 + i] = ws[(i + 1) * stride + 16]
  for i in 0..<16:
    dec.topBorderY[mbx * 16 + i] = ws[16 * stride + 1 + i]
  let lumaW = dec.mbw * 16
  for y in 0..<16:
    for x in 0..<16:
      dec.frame.ybuf[(mby * 16 + y) * lumaW + mbx * 16 + x] =
        ws[(1 + y) * stride + 1 + x]

proc intraPredictChroma(dec: var Vp8Decoder, mbx, mby: int, mb: MacroBlock,
    resdata: array[384, int32]) =
  let stride = 9
  var uws = createBorderChroma(mbx, mby, dec.topBorderU, dec.leftBorderU)
  var vws = createBorderChroma(mbx, mby, dec.topBorderV, dec.leftBorderV)
  case mb.chromaMode
  of cmDc:
    predictDcpred(uws, 8, stride, mby != 0, mbx != 0)
    predictDcpred(vws, 8, stride, mby != 0, mbx != 0)
  of cmV:
    predictVpred(uws, 8, 1, 1, stride)
    predictVpred(vws, 8, 1, 1, stride)
  of cmH:
    predictHpred(uws, 8, 1, 1, stride)
    predictHpred(vws, 8, 1, 1, stride)
  of cmTm:
    predictTmpred(uws, 8, 1, 1, stride)
    predictTmpred(vws, 8, 1, 1, stride)
  for y in 0..<2:
    for x in 0..<2:
      let i = x + y * 2
      var urb: array[16, int32]
      var vrb: array[16, int32]
      for k in 0..<16:
        urb[k] = resdata[16 * 16 + i * 16 + k]
        vrb[k] = resdata[20 * 16 + i * 16 + k]
      addResidue(uws, urb, 1 + y * 4, 1 + x * 4, stride)
      addResidue(vws, vrb, 1 + y * 4, 1 + x * 4, stride)
  setChromaBorder(dec.leftBorderU, dec.topBorderU, uws, mbx)
  setChromaBorder(dec.leftBorderV, dec.topBorderV, vws, mbx)
  let chromaW = dec.mbw * 8
  for y in 0..<8:
    for x in 0..<8:
      dec.frame.ubuf[(mby * 8 + y) * chromaW + mbx * 8 + x] =
        uws[(1 + y) * stride + 1 + x]
      dec.frame.vbuf[(mby * 8 + y) * chromaW + mbx * 8 + x] =
        vws[(1 + y) * stride + 1 + x]

# ---------- loop filter application + params ----------

func calcFilterParams(dec: Vp8Decoder,
    mb: MacroBlock): tuple[level, interior, hev: uint8] =
  let seg = dec.segs[int(mb.segmentId)]
  var level = int32(dec.filterLevel)
  if level == 0: return (0'u8, 0'u8, 0'u8)
  if dec.segmentsEnabled:
    if seg.deltaValues: level += int32(seg.loopfilterLevel)
    else: level = int32(seg.loopfilterLevel)
  level = max(0, min(63, level))
  if dec.lfAdjustEnabled:
    level += dec.refDelta[0]
    if mb.lumaMode == lmB: level += dec.modeDelta[0]
  let fl = uint8(max(0, min(63, level)))
  var interior = int32(fl)
  if dec.sharpness > 0:
    interior = interior shr (if dec.sharpness > 4: 2 else: 1)
    if interior > int32(9 - dec.sharpness):
      interior = int32(9 - dec.sharpness)
  if interior == 0: interior = 1
  var hev = 0'u8
  if dec.filterLevel >= 40: hev = 2
  elif dec.filterLevel >= 15: hev = 1
  (fl, uint8(interior), hev)

proc applyLoopFilter(dec: var Vp8Decoder, mbx, mby: int, mb: MacroBlock) =
  let lumaW = dec.mbw * 16
  let chromaW = dec.mbw * 8
  let (flevel, interior, hev) = calcFilterParams(dec, mb)
  if flevel == 0: return
  let mbedge = (int(flevel) + 2) * 2 + int(interior)
  let subedge = int(flevel) * 2 + int(interior)
  let doSub = mb.lumaMode == lmB or (not mb.coeffsSkipped and mb.nonZeroDct)
  if mbx > 0:
    if dec.filterSimple:
      for y in 0..<16:
        simpleSegmentH(uint8(mbedge), dec.frame.ybuf, (mby * 16 + y) * lumaW + mbx * 16 - 4)
    else:
      for y in 0..<16:
        macroblockFilterH(hev, interior, uint8(mbedge), dec.frame.ybuf,
          (mby * 16 + y) * lumaW + mbx * 16 - 4)
      for y in 0..<8:
        let b = (mby * 8 + y) * chromaW + mbx * 8 - 4
        macroblockFilterH(hev, interior, uint8(mbedge), dec.frame.ubuf, b)
        macroblockFilterH(hev, interior, uint8(mbedge), dec.frame.vbuf, b)
  if doSub:
    if dec.filterSimple:
      for x in countup(4, 14, 4):
        for y in 0..<16:
          simpleSegmentH(uint8(subedge), dec.frame.ybuf,
            (mby * 16 + y) * lumaW + mbx * 16 + x - 4)
    else:
      for x in countup(4, 12, 4):
        for y in 0..<16:
          subblockFilterH(hev, interior, uint8(subedge), dec.frame.ybuf,
            (mby * 16 + y) * lumaW + mbx * 16 + x - 4)
      for y in 0..<8:
        let b = (mby * 8 + y) * chromaW + mbx * 8
        subblockFilterH(hev, interior, uint8(subedge), dec.frame.ubuf, b)
        subblockFilterH(hev, interior, uint8(subedge), dec.frame.vbuf, b)
  if mby > 0:
    if dec.filterSimple:
      for x in 0..<16:
        simpleSegmentV(uint8(mbedge), dec.frame.ybuf, mby * 16 * lumaW + mbx * 16 + x,
          lumaW)
    else:
      for x in 0..<16:
        macroblockFilterV(hev, interior, uint8(mbedge), dec.frame.ybuf,
          mby * 16 * lumaW + mbx * 16 + x, lumaW)
      for x in 0..<8:
        macroblockFilterV(hev, interior, uint8(mbedge), dec.frame.ubuf,
          mby * 8 * chromaW + mbx * 8 + x, chromaW)
        macroblockFilterV(hev, interior, uint8(mbedge), dec.frame.vbuf,
          mby * 8 * chromaW + mbx * 8 + x, chromaW)
  if doSub:
    if dec.filterSimple:
      for y in countup(4, 14, 4):
        for x in 0..<16:
          simpleSegmentV(uint8(subedge), dec.frame.ybuf,
            (mby * 16 + y) * lumaW + mbx * 16 + x, lumaW)
    else:
      for y in countup(4, 12, 4):
        for x in 0..<16:
          subblockFilterV(hev, interior, uint8(subedge), dec.frame.ybuf,
            (mby * 16 + y) * lumaW + mbx * 16 + x, lumaW)
      for x in 0..<8:
        subblockFilterV(hev, interior, uint8(subedge), dec.frame.ubuf,
          (mby * 8 + 4) * chromaW + mbx * 8 + x, chromaW)
        subblockFilterV(hev, interior, uint8(subedge), dec.frame.vbuf,
          (mby * 8 + 4) * chromaW + mbx * 8 + x, chromaW)

# ---------- frame decode + public API ----------

proc decodeFrame(dec: var Vp8Decoder): Vp8Frame =
  dec.readFrameHeader()
  for mby in 0..<dec.mbh:
    let p = mby mod dec.numPartitions
    dec.left = defaultMacroBlock()
    for mbx in 0..<dec.mbw:
      var mb = dec.readMacroblockHeader(mbx)
      var blocks: array[384, int32]
      if not mb.coeffsSkipped:
        blocks = dec.readResidualData(mb, mbx, p)
      else:
        if mb.lumaMode != lmB:
          dec.left.complexity[0] = 0
          dec.top[mbx].complexity[0] = 0
        for i in 1..<9:
          dec.left.complexity[i] = 0
          dec.top[mbx].complexity[i] = 0
      dec.intraPredictLuma(mbx, mby, mb, blocks)
      dec.intraPredictChroma(mbx, mby, mb, blocks)
      dec.macroblocks.add(mb)
    dec.leftBorderY = newSeq[uint8](17)
    for i in 0..<17: dec.leftBorderY[i] = 129
    dec.leftBorderU = newSeq[uint8](9)
    for i in 0..<9: dec.leftBorderU[i] = 129
    dec.leftBorderV = newSeq[uint8](9)
    for i in 0..<9: dec.leftBorderV[i] = 129
  for mby in 0..<dec.mbh:
    for mbx in 0..<dec.mbw:
      let mb = dec.macroblocks[mby * dec.mbw + mbx]
      dec.applyLoopFilter(mbx, mby, mb)
  dec.frame

proc decodeVp8Frame*(data: seq[uint8]): ImageResult[Vp8Frame] =
  ## Decodes a raw VP8 frame (the body of a `VP8 ` RIFF chunk).
  try:
    var dec = initVp8Decoder(data)
    ok(dec.decodeFrame())
  except Vp8DecodeError as e:
    err[Vp8Frame](decodingError(e.msg))

proc vp8ToRgb*(f: Vp8Frame): seq[uint8] =
  ## Packed RGB bytes (width*height*3) via fancy upsampling.
  let bufW = ((f.width + 15) div 16) * 16
  result = newSeq[uint8](f.width * f.height * 3)
  fillRgbFancy(result, f.ybuf, f.ubuf, f.vbuf, f.width, f.height, bufW)
