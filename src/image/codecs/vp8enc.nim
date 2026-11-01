## VP8 lossy intra-only keyframe encoder (pure Nim). Mirrors vp8.nim.
## Scope: still keyframes, single partition, no segments, default token
## probabilities (no adaptation), fixed skip probability. Valid output
## that our decoder (and any spec decoder) accepts; rate-distortion is
## heuristic (SATD mode search, no RDO loop, no loop-filter awareness).
import std/math
import std/algorithm
import ./vp8
import ./vp8tables
import ../error
import ../buffer

# ---------- boolean arithmetic encoder (mirrors BoolDec) ----------

type BoolEnc* = object
  low*: uint32
  range*: uint32
  count*: int
  buf*: seq[uint8]

proc initBoolEnc*(): BoolEnc =
  BoolEnc(low: 0, range: 255, count: -24, buf: @[])

proc renorm(e: var BoolEnc) =
  while e.range < 128:
    e.range += e.range
    if (e.low and 0x80000000'u32) != 0:
      # Carry into the emitted prefix. The all-0xFF (or empty) prefix
      # case cannot propagate: the true value gains a leading 1 byte.
      var x = e.buf.len - 1
      while x >= 0 and e.buf[x] == 0xFF:
        e.buf[x] = 0
        dec x
      if x >= 0:
        e.buf[x] += 1
      else:
        e.buf = @[1'u8] & newSeq[uint8](e.buf.len)
    e.low = e.low shl 1
    e.count += 1
    if e.count == 0:
      e.buf.add(uint8(e.low shr 24))
      e.low = e.low and 0xFFFFFF'u32
      e.count -= 8

proc putBit*(e: var BoolEnc, bit: bool, prob: uint8) =
  let split = 1'u32 + (((e.range - 1) * uint32(prob)) shr 8)
  if bit:
    e.low += split
    e.range -= split
  else:
    e.range = split
  renorm(e)

proc putFlag*(e: var BoolEnc, bit: bool) =
  putBit(e, bit, 128)

proc putLiteral*(e: var BoolEnc, v: uint8, n: int) =
  for i in countdown(n - 1, 0):
    putFlag(e, ((v shr i) and 1) != 0)

proc putSigned*(e: var BoolEnc, v: int32, n: int) =
  ## Mirrors readOptionalSigned: flag, n-bit magnitude, sign.
  if v == 0:
    putFlag(e, false)
  else:
    putFlag(e, true)
    putLiteral(e, uint8(abs(v)), n)
    putFlag(e, v < 0)

proc flush*(e: var BoolEnc) =
  ## Settle all bytes by padding zero bits through the coder (vpx
  ## stop_encode shape). 64 pads yield >= 63 renorms, draining the full
  ## 32-bit register; the decoder stops at real bits and ignores the
  ## tail. Directly dumping `low` would emit unsettled bytes.
  for _ in 0..<64:
    putBit(e, false, 128)

# ---------- quality mapping ----------

func vp8QualityToQi*(quality: int): int =
  clamp((100 - quality) * 127 div 100, 0, 127)

func vp8QualityToFilter*(quality: int): uint8 =
  uint8(clamp((100 - quality) * 20 div 100, 0, 20))

# ---------- RGB -> YUV (BT.601 limited range, inverse of yuvToR/G/B) ----------

func rgbToYuv601*(r, g, b: uint8): tuple[y, u, v: uint8] =
  let fr = int(r); let fg = int(g); let fb = int(b)
  (uint8(clamp((66 * fr + 129 * fg + 25 * fb + 128) shr 8 + 16, 0, 255)),
   uint8(clamp((-38 * fr - 74 * fg + 112 * fb + 128) shr 8 + 128, 0, 255)),
   uint8(clamp((112 * fr - 94 * fg - 18 * fb + 128) shr 8 + 128, 0, 255)))

# ---------- forward transforms (float; gain matches idct4x4/iwht4x4) ----------

const DctMat: array[4, array[4, float64]] = block:
  ## Orthonormal DCT-II 4x4: m[u][x] = sqrt(1/2)*c(u)*cos((2x+1)*u*pi/8).
  var m: array[4, array[4, float64]]
  for u in 0..<4:
    let cu = if u == 0: 1.0 / sqrt(2.0) else: 1.0
    for x in 0..<4:
      m[u][x] = (1.0 / sqrt(2.0)) * cu * cos((2.0 * float64(x) + 1.0) *
        float64(u) * 3.141592653589793 / 8.0)
  m

const FdctGain = 2.0
  ## Matches fdct4x4 to idct4x4: the decoder yields d/8 per pixel for
  ## DC-only input, so quantizing gain*F/qstep round-trips flat blocks
  ## exactly (verified by flat-block tests).
const WhtGain = 1.0
  ## Matches fwht4x4 to iwht4x4 (verified by flat-block tests).

proc fdct4x4*(blk: array[16, float64]): array[16, float64] =
  ## Orthonormal DCT-II. The decoder's integer IDCT computes 8x this, and
  ## its final >>3 divides by 8, so quantizing this output directly by
  ## qstep round-trips (verified by flat-block tests).
  var tmp: array[16, float64]
  for y in 0..<4:
    for u in 0..<4:
      var s = 0.0
      for x in 0..<4:
        s += blk[y * 4 + x] * DctMat[u][x]
      tmp[y * 4 + u] = s
  for v in 0..<4:
    for u in 0..<4:
      var s = 0.0
      for y in 0..<4:
        s += tmp[y * 4 + u] * DctMat[v][y]
      result[v * 4 + u] = s

proc fwht4x4*(blk: array[16, float64]): array[16, float64] =
  ## Unnormalized 2D Walsh-Hadamard. Decoder computes WHT2D/8, so with
  ## quant step q the round-trip needs qw = fw/(8q) (see quantizeWht).
  var tmp = blk
  for i in 0..<4:
    let a0 = tmp[i] + tmp[12 + i]
    let b0 = tmp[4 + i] + tmp[8 + i]
    let c0 = tmp[4 + i] - tmp[8 + i]
    let d0 = tmp[i] - tmp[12 + i]
    tmp[i] = a0 + b0
    tmp[4 + i] = c0 + d0
    tmp[8 + i] = a0 - b0
    tmp[12 + i] = d0 - c0
  for i in 0..<4:
    let a0 = tmp[4 * i] + tmp[4 * i + 3]
    let b0 = tmp[4 * i + 1] + tmp[4 * i + 2]
    let c0 = tmp[4 * i + 1] - tmp[4 * i + 2]
    let d0 = tmp[4 * i] - tmp[4 * i + 3]
    result[4 * i] = a0 + b0
    result[4 * i + 1] = c0 + d0
    result[4 * i + 2] = a0 - b0
    result[4 * i + 3] = d0 - c0

func quantizeCoeff*(v: float64, q: int16): int32 =
  int32(floor(v / float64(q) + 0.5))

# ---------- SATD (mode search distortion) ----------

proc satd4x4(a, b: openArray[uint8]): int =
  var d: array[16, float64]
  for i in 0..<16:
    d[i] = float64(int(a[i]) - int(b[i]))
  let t = fwht4x4(d)
  var s = 0.0
  for v in t:
    s += abs(v)
  int(s)

# ---------- token path tables ----------

type TokPath = seq[tuple[bit: bool, prob: uint8]]

proc findTokPath(nodes: seq[TreeNode], idx: int, value: int8,
    path: var TokPath): bool =
  let n = nodes[idx]
  if int(n.left) < nodes.len:
    if findTokPath(nodes, int(n.left), value, path):
      path.add((false, n.prob))
      return true
  elif int8(n.left and 0x7F'u8) == value:
    path.add((false, n.prob))
    return true
  if int(n.right) < nodes.len:
    if findTokPath(nodes, int(n.right), value, path):
      path.add((true, n.prob))
      return true
  elif int8(n.right and 0x7F'u8) == value:
    path.add((true, n.prob))
    return true
  false

proc buildTokPaths(): array[2, array[4, array[8, array[3, array[12, TokPath]]]]] =
  for s in 0..1:
    for p in 0..<4:
      for bnd in 0..<8:
        for cx in 0..<3:
          let nodes = buildNodes(DctTokenTree, CoeffProbs[p][bnd][cx])
          for tok in 0..11:
            # EOB (11) is unreachable from root 1: after the first DCT_0
            # the block runs explicitly to position 15 (decoder never
            # reads EOB with skip set).
            if s == 1 and tok == 11: continue
            var path: TokPath = @[]
            doAssert findTokPath(nodes, s, int8(tok), path)
            path.reverse()
            result[s][p][bnd][cx][tok] = move(path)

let TokPaths* = buildTokPaths()

proc treeEdgeContains(nodes: seq[TreeNode], edge: uint8, v: int): bool =
  if int(edge) < nodes.len:
    let n = nodes[int(edge)]
    return treeEdgeContains(nodes, n.left, v) or
      treeEdgeContains(nodes, n.right, v)
  int(edge and 0x7F'u8) == v

proc writeTreeVal(e: var BoolEnc, nodes: seq[TreeNode], v: int) =
  var idx = 0
  while idx < nodes.len:
    let n = nodes[idx]
    if treeEdgeContains(nodes, n.left, v):
      e.putBit(false, n.prob)
      when defined(vp8encTrace):
        echo "  modebit 0 prob=", n.prob
      if int(n.left) < nodes.len:
        idx = int(n.left)
      else:
        break
    else:
      e.putBit(true, n.prob)
      when defined(vp8encTrace):
        echo "  modebit 1 prob=", n.prob
      if int(n.right) < nodes.len:
        idx = int(n.right)
      else:
        break

proc writeToken*(e: var BoolEnc, startIdx, plane, band,
    cx, tok: int) =
  for (bit, prob) in TokPaths[startIdx][plane][band][cx][tok]:
    putBit(e, bit, prob)

proc writeExtra*(e: var BoolEnc, ci, extra: int) =
  ## Magnitude refinement bits, MSB-first, same table order as decode.
  var nbits = 0
  for t in ProbDctCat[ci]:
    if t == 0: break
    inc nbits
  for i in countdown(nbits - 1, 0):
    putBit(e, ((extra shr i) and 1) != 0, ProbDctCat[ci][nbits - 1 - i])

proc tokenForAbs(v: int32): tuple[tok, ci, extra: int] =
  if v <= 4:
    (int(v), 0, 0)
  else:
    const Bases = [5, 7, 11, 19, 35, 67]
    const Nbits = [1, 2, 3, 4, 5, 11]
    for ci in 0..5:
      if v < Bases[ci] + (1 shl Nbits[ci]):
        return (5 + ci, ci, int(v) - Bases[ci])
    (10, 5, (1 shl 11) - 1) # clamp: encoder-side saturation, still valid

proc writeCoeffs(e: var BoolEnc, qblk: array[16, int32], plane, cx,
    first: int) =
  ## Mirror of readCoefficients. qblk in natural order.
  var cxv = cx
  var skip = false
  var lastNz = first - 1
  for i in countdown(15, first):
    if qblk[int(Zigzag[i])] != 0:
      lastNz = i
      break
  for i in first..15:
    let band = int(CoeffBands[i])
    let v = qblk[int(Zigzag[i])]
    # EOB is only reachable from root 0: once a DCT_0 was emitted
    # (skip), the block must run explicitly to position 15.
    if i > lastNz and not skip:
      writeToken(e, 0, plane, band, cxv, 11) # EOB
      break
    elif v == 0:
      writeToken(e, if skip: 1 else: 0, plane, band, cxv, 0) # DCT_0
      skip = true
      cxv = 0
    else:
      let av = abs(v)
      let (tok, ci, extra) = tokenForAbs(av)
      writeToken(e, if skip: 1 else: 0, plane, band, cxv, tok)
      if tok >= 5:
        writeExtra(e, ci, extra)
      putFlag(e, v < 0)
      skip = false
      cxv = if av == 0: 0 elif av == 1: 1 else: 2

# ---------- encoder state (mirrors decoder prediction state) ----------

type Vp8Enc = object
  mbw, mbh: int
  ybuf: seq[uint8]
  ubuf, vbuf: seq[uint8]
  topBorderY, leftBorderY: seq[uint8]
  topBorderU, leftBorderU: seq[uint8]
  topBorderV, leftBorderV: seq[uint8]
  topBpred: seq[array[16, IntraMode]]
  leftBpred: array[16, IntraMode]
  topCx: seq[array[9, uint8]]
  leftCx: array[9, uint8]
  # quant tables for this frame
  ydc, yac, y2dc, y2ac, uvdc, uvac: int16

proc initVp8Enc(w, h: int, qi: int): Vp8Enc =
  let mbw = (w + 15) div 16
  let mbh = (h + 15) div 16
  result.mbw = mbw
  result.mbh = mbh
  result.ybuf = newSeq[uint8](mbw * 16 * mbh * 16)
  result.ubuf = newSeq[uint8](mbw * 8 * mbh * 8)
  result.vbuf = newSeq[uint8](mbw * 8 * mbh * 8)
  result.topBorderY = newSeq[uint8](mbw * 16 + 4 + 16)
  for i in 0..<result.topBorderY.len: result.topBorderY[i] = 127
  result.leftBorderY = newSeq[uint8](17)
  for i in 0..<17: result.leftBorderY[i] = 129
  result.topBorderU = newSeq[uint8](8 * mbw)
  for i in 0..<result.topBorderU.len: result.topBorderU[i] = 127
  result.leftBorderU = newSeq[uint8](9)
  for i in 0..<9: result.leftBorderU[i] = 129
  result.topBorderV = newSeq[uint8](8 * mbw)
  for i in 0..<result.topBorderV.len: result.topBorderV[i] = 127
  result.leftBorderV = newSeq[uint8](9)
  for i in 0..<9: result.leftBorderV[i] = 129
  result.topBpred = newSeq[array[16, IntraMode]](mbw)
  for i in 0..<mbw:
    for k in 0..<16:
      result.topBpred[i][k] = imDc
  for k in 0..<16:
    result.leftBpred[k] = imDc
  result.topCx = newSeq[array[9, uint8]](mbw)
  let b = int32(qi)
  result.ydc = DcQuant[max(0, min(127, b))]
  result.yac = AcQuant[max(0, min(127, b))]
  result.y2dc = DcQuant[max(0, min(127, b))] * 2
  result.y2ac = max(8'i16, int16((int32(AcQuant[max(0, min(127, b))]) * 155) div 100))
  result.uvdc = DcQuant[max(0, min(127, b))]
  if result.uvdc > 132: result.uvdc = 132
  result.uvac = AcQuant[max(0, min(127, b))]

# ---------- frame assembly ----------

func blockHasCoeffs(blk: array[16, int32], first: int): bool =
  for i in first..<16:
    if blk[i] != 0: return true
  false

proc encodeVp8Lossy*(img: RgbaImage, quality: int): ImageResult[seq[uint8]] =
  ## Intra-only VP8 keyframe. Returns the raw VP8 frame bitstream
  ## (body of a `VP8 ` RIFF chunk); wrap with encodeWebpLossy.
  if quality < 1 or quality > 100:
    return err[seq[uint8]](paramError(pkGeneric, "webp: quality 1..100"))
  let w = int(img.width); let h = int(img.height)
  if w == 0 or h == 0:
    return err[seq[uint8]](paramError(pkDimensionMismatch, "webp: empty"))
  if w > 16384 or h > 16384:
    return err[seq[uint8]](limitError(lkDimensionError, "webp: too large"))
  let qi = vp8QualityToQi(quality)
  var enc = initVp8Enc(w, h, qi)
  let mbw = enc.mbw; let mbh = enc.mbh

  # --- RGB -> YUV420, edge-padded to the MB grid ---
  var ypl = newSeq[uint8](mbw * 16 * mbh * 16)
  var upl = newSeq[uint8](mbw * 8 * mbh * 8)
  var vpl = newSeq[uint8](mbw * 8 * mbh * 8)
  for y in 0..<mbh * 16:
    let sy = min(y, h - 1)
    for x in 0..<mbw * 16:
      let sx = min(x, w - 1)
      let p = img.pixels[sy * w + sx]
      let (yy, _, _) = rgbToYuv601(p.data[0], p.data[1], p.data[2])
      ypl[y * mbw * 16 + x] = yy
  # 4:2:0 box average over available samples (edges replicate)
  for y in 0..<(mbh * 8):
    for x in 0..<(mbw * 8):
      var su, sv, n = 0
      for dy in 0..1:
        for dx in 0..1:
          let sx = x * 2 + dx; let sy = y * 2 + dy
          if sx < w and sy < h:
            let p = img.pixels[sy * w + sx]
            let (_, uu, vv) = rgbToYuv601(p.data[0], p.data[1], p.data[2])
            su += int(uu); sv += int(vv); inc n
      if n == 0:
        upl[y * mbw * 8 + x] = 128
        vpl[y * mbw * 8 + x] = 128
      else:
        upl[y * mbw * 8 + x] = uint8((su + n div 2) div n)
        vpl[y * mbw * 8 + x] = uint8((sv + n div 2) div n)

  var hdr = initBoolEnc()
  var part = initBoolEnc()

  # --- bool header (mirrors readFrameHeader) ---
  hdr.putLiteral(0, 1) # colorspace
  hdr.putLiteral(0, 1) # pixel type
  hdr.putFlag(false) # segments disabled
  hdr.putFlag(false) # normal (non-simple) loop filter
  hdr.putLiteral(vp8QualityToFilter(quality), 6)
  hdr.putLiteral(0, 3) # sharpness
  hdr.putFlag(false) # no lf adjustments
  hdr.putLiteral(0, 2) # 1 partition
  hdr.putLiteral(uint8(qi), 7) # yacAbs
  for _ in 0..<5:
    hdr.putFlag(false) # all quant deltas zero
  hdr.putLiteral(0, 1) # refresh entropy probabilities: no
  for i in 0..<4:
    for j in 0..<8:
      for k in 0..<3:
        for t in 0..<11:
          hdr.putBit(false, CoeffUpdateProbs[i][j][k][t])
  hdr.putLiteral(1, 1) # mbNoSkip
  hdr.putLiteral(64, 8) # skip probability 64
  # NOTE: no flush here — per-MB skip/mode bits follow into this same
  # control stream inside the macroblock loop below.

  # --- macroblocks ---
  for mby in 0..<mbh:
    enc.leftBpred = [imDc, imDc, imDc, imDc, imDc, imDc, imDc, imDc,
      imDc, imDc, imDc, imDc, imDc, imDc, imDc, imDc]
    for i in 0..<9: enc.leftCx[i] = 0
    for mbx in 0..<mbw:
      # source blocks
      var srcY: array[256, uint8]
      for y in 0..<16:
        for x in 0..<16:
          srcY[y * 16 + x] = ypl[(mby * 16 + y) * mbw * 16 + mbx * 16 + x]
      var srcU, srcV: array[64, uint8]
      for y in 0..<8:
        for x in 0..<8:
          srcU[y * 8 + x] = upl[(mby * 8 + y) * mbw * 8 + mbx * 8 + x]
          srcV[y * 8 + x] = vpl[(mby * 8 + y) * mbw * 8 + mbx * 8 + x]

      # luma 16x16 search (exact: border-only predictors)
      var ws = createBorderLuma(mbx, mby, mbw, enc.topBorderY, enc.leftBorderY)
      var bestMode = lmDc
      var bestSatd = high(int)
      for m in [lmDc, lmV, lmH, lmTm]:
        var trial = ws
        case m
        of lmV: predictVpred(trial, 16, 1, 1, 21)
        of lmH: predictHpred(trial, 16, 1, 1, 21)
        of lmTm: predictTmpred(trial, 16, 1, 1, 21)
        of lmDc: predictDcpred(trial, 16, 21, mby != 0, mbx != 0)
        else: discard
        var s = 0
        for y in 0..<16:
          for x in 0..<16:
            s += abs(int(trial[(1 + y) * 21 + 1 + x]) - int(srcY[y * 16 + x]))
        if s < bestSatd:
          bestSatd = s
          bestMode = m

      # luma 4x4 search (source neighbors as reconstruction proxy)
      var bmodes: array[16, IntraMode]
      var satd4 = 0
      var prox = srcY # neighbor proxy for blocks below/right of (0,0)
      for sby in 0..<4:
        for sbx in 0..<4:
          let i = sbx + sby * 4
          var scr = newSeq[uint8](81)
          # 9x9 scratch: corner + top row + left col from proxy/borders
          let gx = mbx * 16 + sbx * 4
          let gy = mby * 16 + sby * 4
          for k in 0..<9:
            let px = gx - 1 + k
            scr[k] =
              if gy == 0: 127'u8
              elif px < 0: 129'u8
              elif px >= mbw * 16: prox[sby * 4 * 16 + sbx * 4 + 7]
              else: enc.ybuf[(gy - 1) * mbw * 16 + px]
          for k in 0..<9:
            let py = gy - 1 + k
            scr[k * 9] =
              if gx == 0: 129'u8
              elif py < 0: 127'u8
              elif py >= mbh * 16: prox[min(sby * 4 + 7, 15) * 16 + sbx * 4]
              else: enc.ybuf[py * mbw * 16 + gx - 1]
          var tgt: array[16, uint8]
          for y in 0..<4:
            for x in 0..<4:
              tgt[y * 4 + x] = prox[(sby * 4 + y) * 16 + sbx * 4 + x]
          var bestBm = imDc
          var bestBs = high(int)
          for bm in [imDc, imTm, imVe, imHe, imLd, imRd, imVr, imVl,
              imHd, imHu]:
            var t2 = scr
            case bm
            of imTm: predictTmpred(t2, 4, 1, 1, 9)
            of imVe: predictBvepred(t2, 1, 1, 9)
            of imHe: predictBhepred(t2, 1, 1, 9)
            of imDc: predictBdcpred(t2, 1, 1, 9)
            of imLd: predictBldpred(t2, 1, 1, 9)
            of imRd: predictBrdpred(t2, 1, 1, 9)
            of imVr: predictBvrpred(t2, 1, 1, 9)
            of imVl: predictBvlpred(t2, 1, 1, 9)
            of imHd: predictBhdpred(t2, 1, 1, 9)
            of imHu: predictBhupred(t2, 1, 1, 9)
            var pred: array[16, uint8]
            for y in 0..<4:
              for x in 0..<4:
                pred[y * 4 + x] = t2[(1 + y) * 9 + 1 + x]
            let s = satd4x4(pred, tgt)
            if s < bestBs:
              bestBs = s
              bestBm = bm
          bmodes[i] = bestBm
          satd4 += bestBs
      let useSplit = satd4 + 8 * int(enc.yac) < bestSatd
      let lumaMode = if useSplit: lmB else: bestMode
      when defined(vp8encTrace):
        if mbx == 0 and mby == 0:
          echo "mb00 mode=", lumaMode,
            " satd16=", bestSatd, " satd4=", satd4

      # chroma search
      var uws = createBorderChroma(mbx, mby, enc.topBorderU, enc.leftBorderU)
      var vws = createBorderChroma(mbx, mby, enc.topBorderV, enc.leftBorderV)
      var bestCm = cmDc
      var bestCs = high(int)
      for cm in [cmDc, cmV, cmH, cmTm]:
        var tu = uws; var tv = vws
        case cm
        of cmDc:
          predictDcpred(tu, 8, 9, mby != 0, mbx != 0)
          predictDcpred(tv, 8, 9, mby != 0, mbx != 0)
        of cmV:
          predictVpred(tu, 8, 1, 1, 9)
          predictVpred(tv, 8, 1, 1, 9)
        of cmH:
          predictHpred(tu, 8, 1, 1, 9)
          predictHpred(tv, 8, 1, 1, 9)
        of cmTm:
          predictTmpred(tu, 8, 1, 1, 9)
          predictTmpred(tv, 8, 1, 1, 9)
        var s = 0
        for y in 0..<8:
          for x in 0..<8:
            s += abs(int(tu[(1 + y) * 9 + 1 + x]) - int(srcU[y * 8 + x]))
            s += abs(int(tv[(1 + y) * 9 + 1 + x]) - int(srcV[y * 8 + x]))
        if s < bestCs:
          bestCs = s
          bestCm = cm

      # residual + quantize
      var qY: array[16, array[16, int32]] # per 4x4 block, natural order
      var qY2: array[16, int32]
      var qU, qV: array[4, array[16, int32]]
      var allZero = true
      if lumaMode == lmB:
        for i in 0..<16:
          let bx = (i mod 4) * 4; let by = (i div 4) * 4
          var ws2 = createBorderLuma(mbx, mby, mbw, enc.topBorderY,
            enc.leftBorderY)
          # predict the single block with chosen mode (interior blocks
          # see source-proxy neighbors, matching the search)
          for y in 0..<by + 4:
            for x in 0..<bx + 4:
              ws2[(1 + y) * 21 + 1 + x] = prox[y * 16 + x]
          case bmodes[i]
          of imTm: predictTmpred(ws2, 4, 1 + bx, 1 + by, 21)
          of imVe: predictBvepred(ws2, 1 + bx, 1 + by, 21)
          of imHe: predictBhepred(ws2, 1 + bx, 1 + by, 21)
          of imDc: predictBdcpred(ws2, 1 + bx, 1 + by, 21)
          of imLd: predictBldpred(ws2, 1 + bx, 1 + by, 21)
          of imRd: predictBrdpred(ws2, 1 + bx, 1 + by, 21)
          of imVr: predictBvrpred(ws2, 1 + bx, 1 + by, 21)
          of imVl: predictBvlpred(ws2, 1 + bx, 1 + by, 21)
          of imHd: predictBhdpred(ws2, 1 + bx, 1 + by, 21)
          of imHu: predictBhupred(ws2, 1 + bx, 1 + by, 21)
          var blk: array[16, float64]
          for y in 0..<4:
            for x in 0..<4:
              blk[y * 4 + x] = float64(int(prox[(by + y) * 16 + bx + x])) -
                float64(int(ws2[(1 + by + y) * 21 + 1 + bx + x]))
          let f = fdct4x4(blk)
          for k in 0..<16:
            let q = if k == 0: enc.ydc else: enc.yac
            qY[i][k] = quantizeCoeff(f[k] * FdctGain, q)
            if qY[i][k] != 0: allZero = false
      else:
        var ws3 = createBorderLuma(mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        case lumaMode
        of lmV: predictVpred(ws3, 16, 1, 1, 21)
        of lmH: predictHpred(ws3, 16, 1, 1, 21)
        of lmTm: predictTmpred(ws3, 16, 1, 1, 21)
        of lmDc: predictDcpred(ws3, 16, 21, mby != 0, mbx != 0)
        else: discard
        var dcBlks: array[16, float64]
        for i in 0..<16:
          let bx = (i mod 4) * 4; let by = (i div 4) * 4
          var blk: array[16, float64]
          for y in 0..<4:
            for x in 0..<4:
              blk[y * 4 + x] = float64(int(srcY[(by + y) * 16 + bx + x])) -
                float64(int(ws3[(1 + by + y) * 21 + 1 + bx + x]))
          let f = fdct4x4(blk)
          dcBlks[i] = f[0]
          for k in 1..<16:
            qY[i][k] = quantizeCoeff(f[k] * FdctGain, enc.yac)
            if qY[i][k] != 0: allZero = false
        let wht = fwht4x4(dcBlks)
        for k in 0..<16:
          let q = if k == 0: enc.y2dc else: enc.y2ac
          qY2[k] = quantizeCoeff(wht[k] * WhtGain, q)
          if qY2[k] != 0: allZero = false
      # write the winning chroma prediction into the workspaces so the
      # residual below is src minus prediction (not src minus zeros)
      case bestCm
      of cmDc:
        predictDcpred(uws, 8, 9, mby != 0, mbx != 0)
        predictDcpred(vws, 8, 9, mby != 0, mbx != 0)
      of cmV:
        predictVpred(uws, 8, 1, 1, 9)
        predictVpred(vws, 8, 1, 1, 9)
      of cmH:
        predictHpred(uws, 8, 1, 1, 9)
        predictHpred(vws, 8, 1, 1, 9)
      of cmTm:
        predictTmpred(uws, 8, 1, 1, 9)
        predictTmpred(vws, 8, 1, 1, 9)
      for ci in 0..<2:
        for i in 0..<4:
          let bx = (i mod 2) * 4; let by = (i div 2) * 4
          let src = if ci == 0: srcU else: srcV
          let bord = if ci == 0: uws else: vws
          var blk: array[16, float64]
          for y in 0..<4:
            for x in 0..<4:
              blk[y * 4 + x] = float64(int(src[(by + y) * 8 + bx + x])) -
                float64(int(bord[(1 + by + y) * 9 + 1 + bx + x]))
          let f = fdct4x4(blk)
          for k in 0..<16:
            let q = if k == 0: enc.uvdc else: enc.uvac
            let v = quantizeCoeff(f[k] * FdctGain, q)
            if ci == 0: qU[i][k] = v
            else: qV[i][k] = v
            if v != 0: allZero = false

      # bitstream
      let skipped = allZero
      when defined(vp8encTrace):
        if mbx == 0 and mby == 0:
          echo "mb00 skipped=", skipped, " qY00=", qY[0][0], ",", qY[0][1],
            " qY", (if lumaMode == lmB: "split" else: "16") ,
            " qU00=", qU[0][0], " qV00=", qV[0][0]
      hdr.putBit(skipped, 64) # skip flag: control partition, like modes
      # luma mode (keyframe tree)
      let lmVal = case lumaMode
        of lmDc: 0
        of lmV: 1
        of lmH: 2
        of lmTm: 3
        of lmB: 4
      writeTreeVal(hdr, YmodeNodes, lmVal)
      if lumaMode == lmB:
        for y in 0..<4:
          for x in 0..<4:
            let i = x + y * 4
            let above = ord(enc.topBpred[mbx][12 + x])
            let left = ord(enc.leftBpred[y])
            writeTreeVal(hdr, BpredNodes[above][left], ord(bmodes[i]))
            enc.topBpred[mbx][12 + x] = bmodes[i]
            enc.leftBpred[y] = bmodes[i]
      else:
        let im = case lumaMode
          of lmDc: imDc
          of lmV: imVe
          of lmH: imHe
          of lmTm: imTm
          else: imDc
        for i in 0..<4:
          enc.leftBpred[i] = im
      let cmVal = case bestCm
        of cmDc: 0
        of cmV: 1
        of cmH: 2
        of cmTm: 3
      writeTreeVal(hdr, UvNodes, cmVal)
      if not skipped:
        if lumaMode == lmB:
          for y in 0..<4:
            for x in 0..<4:
              let i = x + y * 4
              let cx = int(enc.topCx[mbx][x + 1]) + int(enc.leftCx[y + 1])
              var blk: array[16, int32]
              for k in 0..<16: blk[k] = qY[i][k]
              part.writeCoeffs(blk, 3, cx, 0)
              let n = blockHasCoeffs(blk, 0)
              enc.leftCx[y + 1] = (if n: 1 else: 0)
              enc.topCx[mbx][x + 1] = (if n: 1 else: 0)
        else:
          let cx0 = int(enc.topCx[mbx][0]) + int(enc.leftCx[0])
          var y2: array[16, int32]
          for k in 0..<16: y2[k] = qY2[k]
          part.writeCoeffs(y2, 1, cx0, 0)
          let n0 = blockHasCoeffs(y2, 0)
          enc.leftCx[0] = (if n0: 1 else: 0)
          enc.topCx[mbx][0] = (if n0: 1 else: 0)
          for y in 0..<4:
            var leftCx = enc.leftCx[y + 1]
            for x in 0..<4:
              let i = x + y * 4
              let cx = int(enc.topCx[mbx][x + 1]) + int(leftCx)
              var blk: array[16, int32]
              blk[0] = qY[i][0]
              for k in 1..<16: blk[k] = qY[i][k]
              part.writeCoeffs(blk, 0, cx, 1)
              let n = blockHasCoeffs(blk, 1)
              leftCx = (if n: 1 else: 0)
              enc.topCx[mbx][x + 1] = (if n: 1 else: 0)
            enc.leftCx[y + 1] = leftCx
        for j in [5, 7]:
          for y in 0..<2:
            var leftCx = enc.leftCx[y + j]
            for x in 0..<2:
              let i = x + y * 2
              let cx = int(enc.topCx[mbx][x + j]) + int(leftCx)
              var blk: array[16, int32]
              let src = if j == 5: qU[i] else: qV[i]
              for k in 0..<16: blk[k] = src[k]
              part.writeCoeffs(blk, 2, cx, 0)
              let n = blockHasCoeffs(blk, 0)
              leftCx = (if n: 1 else: 0)
              enc.topCx[mbx][x + j] = (if n: 1 else: 0)
            enc.leftCx[y + j] = leftCx
      else:
        enc.leftCx[0] = 0
        enc.topCx[mbx][0] = 0
        for i in 1..<9:
          enc.leftCx[i] = 0
          enc.topCx[mbx][i] = 0

      # reconstruction (mirrors intraPredictLuma/Chroma, unfiltered)
      if lumaMode == lmB:
        var ws = createBorderLuma(mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        var resdata: array[384, int32]
        for i in 0..<16:
          var blk: array[16, int32]
          blk[0] = qY[i][0] * enc.ydc
          for k in 1..<16: blk[k] = qY[i][k] * enc.yac
          idct4x4(blk)
          for k in 0..<16: resdata[i * 16 + k] = blk[k]
        # predict each block then add residue (predict4x4 equivalent
        # with chosen modes)
        for sby in 0..<4:
          for sbx in 0..<4:
            let i = sbx + sby * 4
            let y0 = sby * 4 + 1
            let x0 = sbx * 4 + 1
            case bmodes[i]
            of imTm: predictTmpred(ws, 4, x0, y0, 21)
            of imVe: predictBvepred(ws, x0, y0, 21)
            of imHe: predictBhepred(ws, x0, y0, 21)
            of imDc: predictBdcpred(ws, x0, y0, 21)
            of imLd: predictBldpred(ws, x0, y0, 21)
            of imRd: predictBrdpred(ws, x0, y0, 21)
            of imVr: predictBvrpred(ws, x0, y0, 21)
            of imVl: predictBvlpred(ws, x0, y0, 21)
            of imHd: predictBhdpred(ws, x0, y0, 21)
            of imHu: predictBhupred(ws, x0, y0, 21)
            var rb: array[16, int32]
            for k in 0..<16: rb[k] = resdata[i * 16 + k]
            addResidue(ws, rb, y0, x0, 21)
        enc.leftBorderY[0] = ws[16]
        for i in 0..<16:
          enc.leftBorderY[1 + i] = ws[(i + 1) * 21 + 16]
          enc.topBorderY[mbx * 16 + i] = ws[16 * 21 + 1 + i]
        for y in 0..<16:
          for x in 0..<16:
            enc.ybuf[(mby * 16 + y) * mbw * 16 + mbx * 16 + x] =
              ws[(1 + y) * 21 + 1 + x]
      else:
        var ws = createBorderLuma(mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        case lumaMode
        of lmV: predictVpred(ws, 16, 1, 1, 21)
        of lmH: predictHpred(ws, 16, 1, 1, 21)
        of lmTm: predictTmpred(ws, 16, 1, 1, 21)
        of lmDc: predictDcpred(ws, 16, 21, mby != 0, mbx != 0)
        else: discard
        var y2d: array[16, int32]
        for k in 0..<16:
          y2d[k] = qY2[k] * (if k == 0: enc.y2dc else: enc.y2ac)
        iwht4x4(y2d)
        for y in 0..<4:
          for x in 0..<4:
            let i = x + y * 4
            var rb: array[16, int32]
            rb[0] = y2d[i]
            for k in 1..<16: rb[k] = qY[i][k] * enc.yac
            # DC dequant note: plane-0 blocks store WHT DC in [0];
            # AC coeffs use yac including position 0 slot (unused)
            idct4x4(rb)
            addResidue(ws, rb, 1 + y * 4, 1 + x * 4, 21)
        enc.leftBorderY[0] = ws[16]
        for i in 0..<16:
          enc.leftBorderY[1 + i] = ws[(i + 1) * 21 + 16]
          enc.topBorderY[mbx * 16 + i] = ws[16 * 21 + 1 + i]
        for y in 0..<16:
          for x in 0..<16:
            enc.ybuf[(mby * 16 + y) * mbw * 16 + mbx * 16 + x] =
              ws[(1 + y) * 21 + 1 + x]
      var uwsF = createBorderChroma(mbx, mby, enc.topBorderU, enc.leftBorderU)
      var vwsF = createBorderChroma(mbx, mby, enc.topBorderV, enc.leftBorderV)
      case bestCm
      of cmDc:
        predictDcpred(uwsF, 8, 9, mby != 0, mbx != 0)
        predictDcpred(vwsF, 8, 9, mby != 0, mbx != 0)
      of cmV:
        predictVpred(uwsF, 8, 1, 1, 9)
        predictVpred(vwsF, 8, 1, 1, 9)
      of cmH:
        predictHpred(uwsF, 8, 1, 1, 9)
        predictHpred(vwsF, 8, 1, 1, 9)
      of cmTm:
        predictTmpred(uwsF, 8, 1, 1, 9)
        predictTmpred(vwsF, 8, 1, 1, 9)
      for y in 0..<2:
        for x in 0..<2:
          let i = x + y * 2
          var urb, vrb: array[16, int32]
          for k in 0..<16:
            urb[k] = qU[i][k] * (if k == 0: enc.uvdc else: enc.uvac)
            vrb[k] = qV[i][k] * (if k == 0: enc.uvdc else: enc.uvac)
          idct4x4(urb)
          idct4x4(vrb)
          addResidue(uwsF, urb, 1 + y * 4, 1 + x * 4, 9)
          addResidue(vwsF, vrb, 1 + y * 4, 1 + x * 4, 9)
      setChromaBorder(enc.leftBorderU, enc.topBorderU, uwsF, mbx)
      setChromaBorder(enc.leftBorderV, enc.topBorderV, vwsF, mbx)
      for y in 0..<8:
        for x in 0..<8:
          enc.ubuf[(mby * 8 + y) * mbw * 8 + mbx * 8 + x] =
            uwsF[(1 + y) * 9 + 1 + x]
          enc.vbuf[(mby * 8 + y) * mbw * 8 + mbx * 8 + x] =
            vwsF[(1 + y) * 9 + 1 + x]
    enc.leftBorderY = newSeq[uint8](17)
    for i in 0..<17: enc.leftBorderY[i] = 129
    enc.leftBorderU = newSeq[uint8](9)
    for i in 0..<9: enc.leftBorderU[i] = 129
    enc.leftBorderV = newSeq[uint8](9)
    for i in 0..<9: enc.leftBorderV[i] = 129

  hdr.flush()
  part.flush()

  # --- frame tag + uncompressed header ---
  var frame = newSeq[uint8]()
  let firstSize = hdr.buf.len
  let tag = (firstSize shl 5) or (1 shl 4) # keyframe, version 0, showframe
  frame.add([uint8(tag and 0xFF), uint8((tag shr 8) and 0xFF),
    uint8((tag shr 16) and 0xFF)])
  frame.add([0x9D'u8, 0x01, 0x2A])
  frame.add([uint8(w and 0xFF), uint8((w shr 8) and 0xFF)])
  frame.add([uint8(h and 0xFF), uint8((h shr 8) and 0xFF)])
  for b in hdr.buf: frame.add(b)
  for b in part.buf: frame.add(b)
  ok(frame)

proc encodeWebpLossy*(img: RgbaImage, quality: int): ImageResult[seq[uint8]] =
  ## Lossy WebP (VP8 keyframe in a `VP8 ` RIFF chunk).
  let f = encodeVp8Lossy(img, quality)
  if not f.ok: return err[seq[uint8]](f.err)
  let payload = f.value
  var output = @[uint8('R'), uint8('I'), uint8('F'), uint8('F')]
  let total = 4 + 8 + payload.len
  let pad = payload.len and 1
  for k in 0..3: output.add(uint8(((total + pad) shr (8 * k)) and 0xFF))
  output.add([uint8('W'), uint8('E'), uint8('B'), uint8('P')])
  output.add([uint8('V'), uint8('P'), uint8('8'), uint8(' ')])
  let n = uint32(payload.len)
  for k in 0..3: output.add(uint8((n shr (8 * k)) and 0xFF))
  for b in payload: output.add(b)
  if pad == 1: output.add(0)
  ok(output)
