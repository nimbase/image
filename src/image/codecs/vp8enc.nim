## VP8 lossy intra-only keyframe encoder (pure Nim). Mirrors vp8.nim.
## Scope: still keyframes, single partition, no segments, default token
## probabilities (no adaptation), fixed skip probability. Valid output
## that our decoder (and any spec decoder) accepts; rate-distortion is
## RDO mode search over fully-quantized candidates, no trellis and no
## loop-filter awareness.
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

# ---------- RDO rate estimation (Phase B) ----------
#
# Mode decisions minimize J = SSD + lambda*rate over fully-quantized
# candidates. Rates come from the default token probabilities (no
# adaptation): each coded bit costs -log2 of its probability, mirroring
# the bool coder's split. Distortion is post-reconstruction SSD.

func bitCost*(prob: uint8, bit: bool): float64 =
  ## -log2 cost of coding `bit` with VP8 probability `prob`. The bool
  ## coder gives the 0-branch a `range * prob/256` split, i.e.
  ## prob/256 = P(0): a 0-bit with prob=1 costs ~8 bits, with
  ## prob=255 nearly nothing. (Getting this backwards inverts every
  ## skewed token/mode cost and actively misleads RDO.)
  let q = if bit: 1.0 - float64(prob) / 256.0 else: float64(prob) / 256.0
  if q <= 0.0: 30.0
  elif q >= 1.0: 0.0
  else: -log2(q)

type TokCostTable* = array[2, array[4, array[8, array[3, array[12, float64]]]]]

let TokCosts* = block:
  ## -log2 bit cost of every (start, plane, band, cx, token) path.
  var t: TokCostTable
  for s in 0..1:
    for p in 0..<4:
      for bnd in 0..<8:
        for cx in 0..<3:
          for tok in 0..11:
            if s == 1 and tok == 11: continue # unreachable, as in TokPaths
            var c = 0.0
            for (bit, prob) in TokPaths[s][p][bnd][cx][tok]:
              c += bitCost(prob, bit)
            t[s][p][bnd][cx][tok] = c
  t

var CurTokCosts* = TokCosts
  ## Per-frame token bit costs. Equals TokCosts until adaptive probs
  ## (Phase C part 2) install refined tables; RDO and trellis always
  ## read CurTokCosts so both automatically benefit.

proc treeEdgeContains(nodes: seq[TreeNode], edge: uint8, v: int): bool =
  if int(edge) < nodes.len:
    let n = nodes[int(edge)]
    return treeEdgeContains(nodes, n.left, v) or
      treeEdgeContains(nodes, n.right, v)
  int(edge and 0x7F'u8) == v

proc treeCost*(nodes: seq[TreeNode], v: int): float64 =
  ## Signaling cost of value v through a mode tree (mirrors writeTreeVal).
  var idx = 0
  while idx < nodes.len:
    let n = nodes[idx]
    if treeEdgeContains(nodes, n.left, v):
      result += bitCost(n.prob, false)
      if int(n.left) < nodes.len: idx = int(n.left)
      else: break
    else:
      result += bitCost(n.prob, true)
      if int(n.right) < nodes.len: idx = int(n.right)
      else: break

# ---------- adaptive token probabilities (Phase C part 2) ----------
#
# The frame header can replace any of the 1056 default token-node
# probabilities (CoeffUpdateProbs-gated flag + 8-bit value each).
# Pass 1 encodes with defaults while counting node visits; pass 2
# installs RD-beneficial updates and re-encodes. The decoder already
# implements updateTokenProbs, so streams stay spec-valid.

proc buildTokNodePaths(): array[2, array[4, array[8,
    array[3, array[12, seq[int]]]]]] =
  ## Node indices traversed for every (start, plane, band, cx, token).
  ## Tree structure is fixed, so paths hold for any probabilities.
  for s in 0..1:
    for p in 0..<4:
      for bnd in 0..<8:
        for cx in 0..<3:
          let nodes = buildNodes(DctTokenTree, CoeffProbs[p][bnd][cx])
          for tok in 0..11:
            if s == 1 and tok == 11: continue # unreachable EOB
            var idx = s
            var path: seq[int] = @[]
            while idx < nodes.len:
              let n = nodes[idx]
              path.add(idx)
              if treeEdgeContains(nodes, n.left, tok):
                if int(n.left) < nodes.len: idx = int(n.left)
                else: break
              else:
                if int(n.right) < nodes.len: idx = int(n.right)
                else: break
            result[s][p][bnd][cx][tok] = move(path)

let TokNodePaths = buildTokNodePaths()

var TokCntL, TokCntR: array[4, array[8, array[3, array[11, int]]]]
  ## Per-node 0/1 visit counts from the latest pass (zeroed per pass).

var CurTokProbs: array[4, array[8, array[3, array[11, uint8]]]]
var TokUpdated: array[4, array[8, array[3, array[11, bool]]]]
var CurTokNodes: array[4, array[8, array[3, seq[TreeNode]]]]
  ## Per-frame emission tables (defaults or pass-2 updates).

var vp8LastNumUpdates*: int
  ## Diagnostic: number of token-prob updates in the last encode.

proc resetTokTablesToDefaults() =
  for p in 0..<4:
    for b in 0..<8:
      for cx in 0..<3:
        CurTokNodes[p][b][cx] = buildNodes(DctTokenTree, CoeffProbs[p][b][cx])
        for t in 0..<11:
          CurTokProbs[p][b][cx][t] = CoeffProbs[p][b][cx][t]
          TokUpdated[p][b][cx][t] = false
  CurTokCosts = TokCosts
  for p in 0..<4:
    for b in 0..<8:
      for cx in 0..<3:
        for t in 0..<11:
          TokCntL[p][b][cx][t] = 0
          TokCntR[p][b][cx][t] = 0

resetTokTablesToDefaults() # module init so direct writeToken use is valid

proc computeTokUpdates() =
  ## Pass-1 visit counts -> per-node RD update decisions. A node updates
  ## iff the new probability saves more token bits than the update costs
  ## (update flag delta at CoeffUpdateProbs + 8-bit value). MLE with
  ## clamp [1,255]; the fixed update cost self-regulates tiny counts.
  vp8LastNumUpdates = 0
  for p in 0..<4:
    for b in 0..<8:
      for cx in 0..<3:
        for nd in 0..<11:
          let L = TokCntL[p][b][cx][nd]
          let R = TokCntR[p][b][cx][nd]
          let pOld = CoeffProbs[p][b][cx][nd]
          if L + R == 0:
            TokUpdated[p][b][cx][nd] = false
            CurTokProbs[p][b][cx][nd] = pOld
            continue
          var pNew = int((256 * R + (L + R) div 2) div (L + R))
          if pNew < 1: pNew = 1
          elif pNew > 255: pNew = 255
          let oldC = float64(L) * bitCost(pOld, false) +
            float64(R) * bitCost(pOld, true)
          let cup = CoeffUpdateProbs[p][b][cx][nd]
          let newC = float64(L) * bitCost(uint8(pNew), false) +
            float64(R) * bitCost(uint8(pNew), true) +
            bitCost(cup, true) + 8.0 - bitCost(cup, false)
          if newC < oldC:
            TokUpdated[p][b][cx][nd] = true
            CurTokProbs[p][b][cx][nd] = uint8(pNew)
            inc vp8LastNumUpdates
          else:
            TokUpdated[p][b][cx][nd] = false
            CurTokProbs[p][b][cx][nd] = pOld

proc rebuildCurTokTables() =
  ## Rebuild per-frame emission nodes + decision costs from CurTokProbs.
  for p in 0..<4:
    for b in 0..<8:
      for cx in 0..<3:
        CurTokNodes[p][b][cx] = buildNodes(DctTokenTree, CurTokProbs[p][b][cx])
  for s in 0..1:
    for p in 0..<4:
      for bnd in 0..<8:
        for cx in 0..<3:
          for tok in 0..11:
            if s == 1 and tok == 11: continue # unreachable EOB
            let nodes = TokNodePaths[s][p][bnd][cx][tok]
            let path = TokPaths[s][p][bnd][cx][tok]
            var c = 0.0
            for zi in 0..<nodes.len:
              c += bitCost(CurTokProbs[p][bnd][cx][nodes[zi]], path[zi].bit)
            CurTokCosts[s][p][bnd][cx][tok] = c

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
  ## Token bits through the CURRENT per-frame node tables (defaults or
  ## pass-2 updates), tallying node visits for adaptation. Directions
  ## come from the fixed tree structure (TokPaths bits); probabilities
  ## from CurTokNodes.
  let nodes = CurTokNodes[plane][band][cx]
  var idx = startIdx
  for (bit, _) in TokPaths[startIdx][plane][band][cx][tok]:
    let n = nodes[idx]
    e.putBit(bit, n.prob)
    if bit:
      TokCntR[plane][band][cx][idx] += 1
      if int(n.right) < nodes.len: idx = int(n.right)
      else: break
    else:
      TokCntL[plane][band][cx][idx] += 1
      if int(n.left) < nodes.len: idx = int(n.left)
      else: break

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

func extraRate*(ci, extra: int): float64 =
  ## Magnitude-refinement bit cost, MSB-first like writeExtra.
  var nbits = 0
  for t in ProbDctCat[ci]:
    if t == 0: break
    inc nbits
  for k in 0..<nbits:
    let bit = ((extra shr (nbits - 1 - k)) and 1) != 0
    result += bitCost(ProbDctCat[ci][k], bit)

proc coeffBlockRate*(qblk: array[16, int32], plane, cx, first: int):
    tuple[rate: float64, hasNz: bool] =
  ## Token-path bit cost of one quantized block (mirrors writeCoeffs).
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
    if i > lastNz and not skip:
      result[0] += CurTokCosts[0][plane][band][cxv][11] # EOB
      break
    elif v == 0:
      result[0] += CurTokCosts[if skip: 1 else: 0][plane][band][cxv][0]
      skip = true
      cxv = 0
    else:
      let av = abs(v)
      let (tok, ci, extra) = tokenForAbs(av)
      result[0] += CurTokCosts[if skip: 1 else: 0][plane][band][cxv][tok]
      if tok >= 5:
        result[0] += extraRate(ci, extra)
      result[0] += 1.0 # sign bit, prob 128
      skip = false
      cxv = if av == 0: 0 elif av == 1: 1 else: 2
  result[1] = lastNz >= first

func ssd16*(a, b: array[256, uint8]): float64 =
  for i in 0..<256:
    let d = float64(int(a[i]) - int(b[i]))
    result += d * d

func ssd8*(a, b: array[64, uint8]): float64 =
  for i in 0..<64:
    let d = float64(int(a[i]) - int(b[i]))
    result += d * d

const RdoLamK = 0.01
  ## J = SSD + lambda*rate with lambda = RdoLamK * q^2. Swept 0.01/0.03/
  ## 0.10/0.30 on the release matrix (tex512 + photo512 at q50/75/90):
  ## 0.01 strictly dominates the old heuristic everywhere (up to -39%
  ## size at +1.3 dB on texture; -2..-6% size at +0.1~0.2 dB on photo).

func vp8RdoLambda*(qac: int16): float64 =
  RdoLamK * float64(qac) * float64(qac)

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

# ---------- reusable border scratch (encoder-local) ----------
#
# The RDO search and the final pipeline build one 21x17 luma border (357 B)
# and 9x9 chroma borders (81 B) per candidate/block. The shared
# `createBorderLuma/Chroma` (vp8.nim) allocate a fresh seq per call, which is
# hundreds of thousands of small allocations per photo encode. These fill
# variants compute byte-identical borders into caller-owned backing, reused
# per MB in runVp8Pass, so the hot loop stays allocation-free in steady
# state. The decoder keeps using the allocating originals untouched.
#
# NOTE: shaped as `initPool`/`clear`/`.data` buffalo pools on purpose — once
# nimbase/buffalo is public and registered in the Nim package list, swap
# the plain seqs below for buffalo PooledBuffers (same clear+reuse shape).

proc fillBorderLuma*(dst: var seq[uint8], mbx, mby, mbw: int,
    top, left: seq[uint8]) =
  if dst.len < 357: dst.setLen(357)
  # Zero the backing first: createBorderLuma starts from a zeroed seq and
  # only writes the border regions, so predictors must observe zeros (not
  # previous-MB garbage) in the untouched interior. One 357 B memset per
  # call is noise next to the float64 DCT work that follows.
  zeroMem(addr dst[0], 357)
  let stride = 21
  if mby == 0:
    for i in 1..<stride: dst[i] = 127
  else:
    for i in 0..<16: dst[1 + i] = top[mbx * 16 + i]
    if mbx == mbw - 1:
      for i in 16..<20: dst[1 + i] = top[mbx * 16 + 15]
    else:
      for i in 16..<20: dst[1 + i] = top[mbx * 16 + i]
  for i in 17..<stride:
    dst[4 * stride + i] = dst[i]
    dst[8 * stride + i] = dst[i]
    dst[12 * stride + i] = dst[i]
  if mbx == 0:
    for i in 0..<16: dst[(i + 1) * stride] = 129
  else:
    for i in 0..<16: dst[(i + 1) * stride] = left[1 + i]
  dst[0] =
    if mby == 0: 127'u8
    elif mbx == 0: 129'u8
    else: left[0]

proc fillBorderChroma*(dst: var seq[uint8], mbx, mby: int,
    top, left: seq[uint8]) =
  if dst.len < 81: dst.setLen(81)
  zeroMem(addr dst[0], 81)
  let stride = 9
  if mby == 0:
    for i in 1..<stride: dst[i] = 127
  else:
    for i in 0..<8: dst[1 + i] = top[mbx * 8 + i]
  if mbx == 0:
    for y in 0..<8: dst[(y + 1) * stride] = 129
  else:
    for y in 0..<8: dst[(y + 1) * stride] = left[1 + y]
  dst[0] =
    if mby == 0: 127'u8
    elif mbx == 0: 129'u8
    else: left[0]

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

# ---------- RDO candidate evaluation (Phase B) ----------
#
# Each helper mirrors one stage of the final MB pipeline (same predictors,
# same quantizers, same dequant+IDCT reconstruction) so the RD cost J of
# a candidate equals what the bitstream section would produce for it.
# Eval procs never mutate encoder state; the winner is re-derived by the
# existing pipeline, keeping a single source of truth for emission.

proc rdoPredictLuma16(m: LumaMode, mbx, mby, mbw: int, topB,
    leftB: seq[uint8], ws: var seq[uint8]): array[256, uint8] =
  fillBorderLuma(ws, mbx, mby, mbw, topB, leftB)
  case m
  of lmV: predictVpred(ws, 16, 1, 1, 21)
  of lmH: predictHpred(ws, 16, 1, 1, 21)
  of lmTm: predictTmpred(ws, 16, 1, 1, 21)
  of lmDc: predictDcpred(ws, 16, 21, mby != 0, mbx != 0)
  of lmB: discard
  for y in 0..<16:
    for x in 0..<16:
      result[y * 16 + x] = ws[(1 + y) * 21 + 1 + x]

proc rdoQuantLuma16(pred, src: array[256, uint8], ydc, yac, y2dc,
    y2ac: int16): tuple[qY: array[16, array[16, int32]],
    qY2: array[16, int32], allZero: bool] =
  var dcBlks: array[16, float64]
  result.allZero = true
  for i in 0..<16:
    let bx = (i mod 4) * 4; let by = (i div 4) * 4
    var blk: array[16, float64]
    for y in 0..<4:
      for x in 0..<4:
        blk[y * 4 + x] = float64(int(src[(by + y) * 16 + bx + x])) -
          float64(int(pred[(by + y) * 16 + bx + x]))
    let f = fdct4x4(blk)
    dcBlks[i] = f[0]
    for k in 1..<16:
      let q = quantizeCoeff(f[k] * FdctGain, yac)
      result.qY[i][k] = q
      if q != 0: result.allZero = false
  let wht = fwht4x4(dcBlks)
  for k in 0..<16:
    let q = if k == 0: y2dc else: y2ac
    let v = quantizeCoeff(wht[k] * WhtGain, q)
    result.qY2[k] = v
    if v != 0: result.allZero = false

proc rdoRateLuma16(qY2: array[16, int32],
    qY: array[16, array[16, int32]], topCx,
    leftCx: array[9, uint8]): float64 =
  ## Coeff rate with sequential cx simulation (mirrors the bitstream loop).
  var tCx = topCx; var lCx = leftCx
  let cx0 = int(tCx[0]) + int(lCx[0])
  var y2: array[16, int32]
  for k in 0..<16: y2[k] = qY2[k]
  let (r0, n0) = coeffBlockRate(y2, 1, cx0, 0)
  result += r0
  tCx[0] = (if n0: 1 else: 0); lCx[0] = (if n0: 1 else: 0)
  for y in 0..<4:
    var l = lCx[y + 1]
    for x in 0..<4:
      let i = x + y * 4
      let cx = int(tCx[x + 1]) + int(l)
      var blk: array[16, int32]
      blk[0] = qY[i][0]
      for k in 1..<16: blk[k] = qY[i][k]
      let (r, n) = coeffBlockRate(blk, 0, cx, 1)
      result += r
      l = (if n: 1 else: 0)
      tCx[x + 1] = (if n: 1 else: 0)
    lCx[y + 1] = l

proc rdoReconLuma16(pred: array[256, uint8],
    qY: array[16, array[16, int32]], qY2: array[16, int32], ydc, yac,
    y2dc, y2ac: int16): array[256, uint8] =
  result = pred
  var y2d: array[16, int32]
  for k in 0..<16:
    y2d[k] = qY2[k] * (if k == 0: y2dc else: y2ac)
  iwht4x4(y2d)
  for y in 0..<4:
    for x in 0..<4:
      let i = x + y * 4
      var rb: array[16, int32]
      rb[0] = y2d[i]
      for k in 1..<16: rb[k] = qY[i][k] * yac
      idct4x4(rb)
      for r in 0..<4:
        for c in 0..<4:
          let v = int(pred[(y * 4 + r) * 16 + x * 4 + c]) + rb[r * 4 + c]
          result[(y * 4 + r) * 16 + x * 4 + c] = uint8(max(0, min(255, v)))

proc rdoQuantSplit(src: array[256, uint8], mbx, mby, mbw: int, topB,
    leftB: seq[uint8], bmodes: array[16, IntraMode], ydc,
    yac: int16, ws: var seq[uint8]): tuple[qY: array[16, array[16, int32]], allZero: bool] =
  ## Split residual vs the source proxy (mirrors the final quant path,
  ## which fills interior workspaces from prox for each block).
  result.allZero = true
  for i in 0..<16:
    let bx = (i mod 4) * 4; let by = (i div 4) * 4
    fillBorderLuma(ws, mbx, mby, mbw, topB, leftB)
    for y in 0..<by + 4:
      for x in 0..<bx + 4:
        ws[(1 + y) * 21 + 1 + x] = src[y * 16 + x]
    case bmodes[i]
    of imTm: predictTmpred(ws, 4, 1 + bx, 1 + by, 21)
    of imVe: predictBvepred(ws, 1 + bx, 1 + by, 21)
    of imHe: predictBhepred(ws, 1 + bx, 1 + by, 21)
    of imDc: predictBdcpred(ws, 1 + bx, 1 + by, 21)
    of imLd: predictBldpred(ws, 1 + bx, 1 + by, 21)
    of imRd: predictBrdpred(ws, 1 + bx, 1 + by, 21)
    of imVr: predictBvrpred(ws, 1 + bx, 1 + by, 21)
    of imVl: predictBvlpred(ws, 1 + bx, 1 + by, 21)
    of imHd: predictBhdpred(ws, 1 + bx, 1 + by, 21)
    of imHu: predictBhupred(ws, 1 + bx, 1 + by, 21)
    var blk: array[16, float64]
    for y in 0..<4:
      for x in 0..<4:
        blk[y * 4 + x] = float64(int(src[(by + y) * 16 + bx + x])) -
          float64(int(ws[(1 + by + y) * 21 + 1 + bx + x]))
    let f = fdct4x4(blk)
    for k in 0..<16:
      let q = if k == 0: ydc else: yac
      let v = quantizeCoeff(f[k] * FdctGain, q)
      result.qY[i][k] = v
      if v != 0: result.allZero = false

proc rdoReconSplit(bmodes: array[16, IntraMode],
    qY: array[16, array[16, int32]], mbx, mby, mbw: int, topB,
    leftB: seq[uint8], ydc, yac: int16,
    ws: var seq[uint8]): array[256, uint8] =
  ## Sequential causal reconstruction (mirrors the final recon path).
  fillBorderLuma(ws, mbx, mby, mbw, topB, leftB)
  var resdata: array[384, int32]
  for i in 0..<16:
    var blk: array[16, int32]
    blk[0] = qY[i][0] * ydc
    for k in 1..<16: blk[k] = qY[i][k] * yac
    idct4x4(blk)
    for k in 0..<16: resdata[i * 16 + k] = blk[k]
  for sby in 0..<4:
    for sbx in 0..<4:
      let i = sbx + sby * 4
      let y0 = sby * 4 + 1; let x0 = sbx * 4 + 1
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
  for y in 0..<16:
    for x in 0..<16:
      result[y * 16 + x] = ws[(1 + y) * 21 + 1 + x]

proc rdoSplitJ(srcY: array[256, uint8], mbx, mby, mbw: int, topB,
    leftB: seq[uint8], bmodes: array[16, IntraMode],
    topBp: array[16, IntraMode], leftBp: array[16, IntraMode], topCx,
    leftCx: array[9, uint8], ydc, yac: int16,
    lambda: float64, ws: var seq[uint8]): tuple[j, ssd, rate: float64] =
  ## Full RD cost of the split candidate (mode + bpred + coeff bits).
  let (qY, allZero) = rdoQuantSplit(srcY, mbx, mby, mbw, topB, leftB,
    bmodes, ydc, yac, ws)
  var rate = treeCost(YmodeNodes, 4)
  var ab: array[4, int]
  for x in 0..<4: ab[x] = ord(topBp[12 + x])
  var tCx = topCx; var lCx = leftCx
  for y in 0..<4:
    var lm = ord(leftBp[y])
    var lc = lCx[y + 1]
    for x in 0..<4:
      let i = x + y * 4
      rate += treeCost(BpredNodes[ab[x]][lm], ord(bmodes[i]))
      if not allZero:
        let cx = int(tCx[x + 1]) + int(lc)
        let (r, n) = coeffBlockRate(qY[i], 3, cx, 0)
        rate += r
        lc = (if n: 1 else: 0)
        tCx[x + 1] = (if n: 1 else: 0)
      ab[x] = ord(bmodes[i]); lm = ord(bmodes[i])
    lCx[y + 1] = lc
  rate += bitCost(64'u8, allZero)
  let recon = rdoReconSplit(bmodes, qY, mbx, mby, mbw, topB, leftB,
    ydc, yac, ws)
  let ssd = ssd16(srcY, recon)
  (ssd + lambda * rate, ssd, rate)

proc rdoPredictChroma(cm: ChromaMode, mbx, mby: int, topU, leftU,
    topV, leftV: seq[uint8], uws, vws: var seq[uint8]): tuple[pu, pv: array[64, uint8]] =
  fillBorderChroma(uws, mbx, mby, topU, leftU)
  fillBorderChroma(vws, mbx, mby, topV, leftV)
  case cm
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
  for y in 0..<8:
    for x in 0..<8:
      result.pu[y * 8 + x] = uws[(1 + y) * 9 + 1 + x]
      result.pv[y * 8 + x] = vws[(1 + y) * 9 + 1 + x]

proc rdoQuantChroma(pu, pv, srcU, srcV: array[64, uint8], uvdc,
    uvac: int16): tuple[qU, qV: array[4, array[16, int32]],
    allZero: bool] =
  result.allZero = true
  for ci in 0..<2:
    for i in 0..<4:
      let bx = (i mod 2) * 4; let by = (i div 2) * 4
      let src = if ci == 0: srcU else: srcV
      let prd = if ci == 0: pu else: pv
      var blk: array[16, float64]
      for y in 0..<4:
        for x in 0..<4:
          blk[y * 4 + x] = float64(int(src[(by + y) * 8 + bx + x])) -
            float64(int(prd[(by + y) * 8 + bx + x]))
      let f = fdct4x4(blk)
      for k in 0..<16:
        let q = if k == 0: uvdc else: uvac
        let v = quantizeCoeff(f[k] * FdctGain, q)
        if ci == 0: result.qU[i][k] = v
        else: result.qV[i][k] = v
        if v != 0: result.allZero = false

proc rdoRateChroma(qU, qV: array[4, array[16, int32]], topCx,
    leftCx: array[9, uint8]): float64 =
  var tCx = topCx; var lCx = leftCx
  for j in [5, 7]:
    for y in 0..<2:
      var lc = lCx[y + j]
      for x in 0..<2:
        let i = x + y * 2
        let cx = int(tCx[x + j]) + int(lc)
        var blk: array[16, int32]
        let src = if j == 5: qU[i] else: qV[i]
        for k in 0..<16: blk[k] = src[k]
        let (r, n) = coeffBlockRate(blk, 2, cx, 0)
        result += r
        lc = (if n: 1 else: 0)
        tCx[x + j] = (if n: 1 else: 0)
      lCx[y + j] = lc

proc rdoReconChroma(pu, pv: array[64, uint8],
    qU, qV: array[4, array[16, int32]], mbx, mby: int, topU, leftU,
    topV, leftV: seq[uint8], uvdc,
    uvac: int16, uws, vws: var seq[uint8]): tuple[ru, rv: array[64, uint8]] =
  fillBorderChroma(uws, mbx, mby, topU, leftU)
  fillBorderChroma(vws, mbx, mby, topV, leftV)
  for y in 0..<8:
    for x in 0..<8:
      uws[(1 + y) * 9 + 1 + x] = pu[y * 8 + x]
      vws[(1 + y) * 9 + 1 + x] = pv[y * 8 + x]
  for y in 0..<2:
    for x in 0..<2:
      let i = x + y * 2
      var urb, vrb: array[16, int32]
      for k in 0..<16:
        urb[k] = qU[i][k] * (if k == 0: uvdc else: uvac)
        vrb[k] = qV[i][k] * (if k == 0: uvdc else: uvac)
      idct4x4(urb)
      idct4x4(vrb)
      addResidue(uws, urb, 1 + y * 4, 1 + x * 4, 9)
      addResidue(vws, vrb, 1 + y * 4, 1 + x * 4, 9)
  for y in 0..<8:
    for x in 0..<8:
      result.ru[y * 8 + x] = uws[(1 + y) * 9 + 1 + x]
      result.rv[y * 8 + x] = vws[(1 + y) * 9 + 1 + x]

const TrellisScale = 0.5
  ## Trellis lambda multiplier: lambdaT = lambda * TrellisScale.
  ## Analytical prior from D_pixel/D_G (~0.27, so ~4x) proved too
  ## aggressive on the matrix (operating point shifted down-quality);
  ## swept 0.5/1.0/2.0/4.0 on tex512+photo512 at q50/75/90 and 0.5
  ## keeps the operating point (q90 strict wins -4..-8% at equal PSNR,
  ## rest neutral-to-positive) while capturing EOB/rounding wins.
  ## The gap vs the analytical prior reflects integer rounding,
  ## clamping, and RDO interaction on marginal decisions.

func trellisLambda*(lambda: float64): float64 = TrellisScale * lambda

proc trellisBlk*(F: array[16, float64], qdc, qac: int16, plane, cx,
    first: int, lambdaT: float64): tuple[q: array[16, int32],
    hasNz: bool] =
  ## RD-optimal levels for one block: forward DP over scan positions
  ## with skip state (DCT_0 emitted or not), candidates {0, base,
  ## alt-rounding} per position plus EOB termination from skip=false.
  ## Mirrors writeCoeffs exactly (same trees, extras, EOB reachability),
  ## so the chosen levels emit verbatim. Distortion is in G units;
  ## caller scales lambda by TrellisScale.
  const Inff = 1e100
  var dp0 = 0.0   # best cost of prefix ending with skip=false
  var dp1 = Inff  # best cost of prefix ending with skip=true
  var choice: array[16, array[2, tuple[lvl: int32, ps: bool]]]
  var bestTerm = Inff
  var bestTermPos = -1
  # Suffix distortion if positions i..15 are all left uncoded (EOB at i
  # drops the tail: its G^2 must be counted, not just the EOB bits).
  var suffixG2: array[17, float64]
  for i in countdown(15, first):
    suffixG2[i] = suffixG2[i + 1] +
      (let zz = int(Zigzag[i]); (F[zz] * FdctGain) * (F[zz] * FdctGain))
  for i in first..15:
    let zz = int(Zigzag[i])
    let bnd = int(CoeffBands[i])
    let G = F[zz] * FdctGain
    let qf = float64(if zz == 0: qdc else: qac)
    let base = quantizeCoeff(G, if zz == 0: qdc else: qac)
    let baseM = abs(base)
    # EOB terminates here (only from skip=false, like writeCoeffs):
    # prefix cost + EOB bits + dropped-tail distortion.
    let termC = dp0 + lambdaT * CurTokCosts[0][plane][bnd][cx][11] +
      suffixG2[i]
    if termC < bestTerm:
      bestTerm = termC
      bestTermPos = i
    # candidate magnitudes: 0 plus base and the other rounding
    var cands: array[3, int32]
    var ncand = 1
    if baseM > 0:
      cands[1] = baseM
      ncand = 2
      let fl = int(abs(G) / qf)
      var alt = if baseM == fl: fl + 1 else: fl
      if alt < 0: alt = 0
      if alt != 0 and alt != baseM:
        cands[2] = int32(alt)
        ncand = 3
    var ndp0 = Inff
    var ndp1 = Inff
    # zero level (sets skip)
    let dzD = G * G
    let z0 = dp0 + dzD + lambdaT * CurTokCosts[0][plane][bnd][cx][0]
    if z0 < ndp1:
      ndp1 = z0
      choice[i][1] = (0'i32, false)
    let z1 = dp1 + dzD + lambdaT * CurTokCosts[1][plane][bnd][cx][0]
    if z1 < ndp1:
      ndp1 = z1
      choice[i][1] = (0'i32, true)
    # nonzero levels (reset skip); take G's sign (rate is sign-agnostic
    # beyond the 1-bit flag, distortion minimal at sign(G))
    for c in 1..<ncand:
      let m = cands[c]
      let L = if G < 0: -m else: m
      let D = (G - float64(L) * qf) * (G - float64(L) * qf)
      let (tok, ci, extra) = tokenForAbs(m)
      var exR = 0.0
      if tok >= 5: exR = extraRate(ci, extra)
      let R0 = CurTokCosts[0][plane][bnd][cx][tok] + exR + 1.0
      let R1 = CurTokCosts[1][plane][bnd][cx][tok] + exR + 1.0
      if dp0 + D + lambdaT * R0 < ndp0:
        ndp0 = dp0 + D + lambdaT * R0
        choice[i][0] = (L, false)
      if dp1 + D + lambdaT * R1 < ndp0:
        ndp0 = dp1 + D + lambdaT * R1
        choice[i][0] = (L, true)
    dp0 = ndp0
    dp1 = ndp1
  # finish: EOB-terminal, run-to-end with skip false (last was value at
  # 15), or run-to-end with skip true (explicit trailing DCT_0s)
  var endPos = 16
  var curSkip = false
  if dp0 <= bestTerm and dp0 <= dp1:
    discard # ends at 15, skip false
  elif dp1 <= bestTerm and dp1 <= dp0:
    curSkip = true
  else:
    endPos = bestTermPos
    curSkip = false
  for i in countdown(min(endPos, 16) - 1, first):
    let (lvl, ps) = choice[i][ord(curSkip)]
    result.q[int(Zigzag[i])] = lvl
    if lvl != 0: result.hasNz = true
    curSkip = ps
  # positions past EOB (or untouched 0) stay zero from init

# ---------- frame assembly ----------

func blockHasCoeffs(blk: array[16, int32], first: int): bool =
  for i in first..<16:
    if blk[i] != 0: return true
  false

proc runVp8Pass(ypl, upl, vpl: seq[uint8], w, h, qi, quality: int,
    hdr, part: var BoolEnc, useUpdates: bool) =
  ## One encode pass: bool header (optionally with token-prob updates)
  ## + macroblock loop. Pass 1 uses defaults and counts tokens;
  ## pass 2 uses RD-beneficial updates. State is fresh per pass.
  var enc = initVp8Enc(w, h, qi)
  let mbw = enc.mbw; let mbh = enc.mbh

  # Reusable border scratch for the MB loop below. Plain seqs allocated
  # once per pass and refilled per use (fillBorder* zero the backing, so no
  # per-MB clear is needed); threaded through the RDO helpers and final
  # pipeline as the `ws` argument, replacing the per-candidate
  # `createBorderLuma/Chroma` allocations. Steady state allocates nothing.
  # Luma (357 B) and the two chroma workspaces (81 B) must be simultaneously
  # live; the SATD scratch is refilled per sub-block.
  var lumaWs = newSeq[uint8](357)
  var chromaA = newSeq[uint8](81)
  var chromaB = newSeq[uint8](81)
  var satdWs = newSeq[uint8](81)

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
          if useUpdates and TokUpdated[i][j][k][t]:
            hdr.putBit(true, CoeffUpdateProbs[i][j][k][t])
            hdr.putLiteral(CurTokProbs[i][j][k][t], 8)
          else:
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

      # luma mode decision: RDO over 4x 16x16 modes + split (Phase B).
      # Each candidate is fully quantized; J = SSD + lambda*rate with
      # lambda ~ q^2. Replaces the SAD/SATD heuristic.
      let lambdaY = vp8RdoLambda(enc.yac)
      let lambdaC = vp8RdoLambda(enc.uvac)
      var tCxY, lCxY: array[9, uint8]
      for i in 0..<9:
        tCxY[i] = enc.topCx[mbx][i]
        lCxY[i] = enc.leftCx[i]
      var bestMode = lmDc
      var bestJ = Inf
      for m in [lmDc, lmV, lmH, lmTm]:
        let pred = rdoPredictLuma16(m, mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY, lumaWs)
        let (qY16, qY216, z16) = rdoQuantLuma16(pred, srcY, enc.ydc,
          enc.yac, enc.y2dc, enc.y2ac)
        let lmVal = case m
          of lmDc: 0
          of lmV: 1
          of lmH: 2
          of lmTm: 3
          of lmB: 4
        var rate = treeCost(YmodeNodes, lmVal)
        var ssd: float64
        if z16:
          rate += bitCost(64'u8, true) # skip flag
          ssd = ssd16(srcY, pred)
        else:
          rate += bitCost(64'u8, false)
          rate += rdoRateLuma16(qY216, qY16, tCxY, lCxY)
          let recon = rdoReconLuma16(pred, qY16, qY216, enc.ydc, enc.yac,
            enc.y2dc, enc.y2ac)
          ssd = ssd16(srcY, recon)
        let j = ssd + lambdaY * rate
        if j < bestJ:
          bestJ = j
          bestMode = m

      # luma 4x4 search (source neighbors as reconstruction proxy)
      var bmodes: array[16, IntraMode]
      var prox = srcY # neighbor proxy for blocks below/right of (0,0)
      for sby in 0..<4:
        for sbx in 0..<4:
          let i = sbx + sby * 4
          var scr = satdWs
          # 9x9 scratch: corner + top row + left col from proxy/borders.
          # Fully refilled every sub-block, so the shared backing is safe.
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
      # split candidate RDO with the SATD-chosen sub-modes
      let (spJ, _, _) = rdoSplitJ(srcY, mbx, mby, mbw, enc.topBorderY,
        enc.leftBorderY, bmodes, enc.topBpred[mbx], enc.leftBpred, tCxY,
        lCxY, enc.ydc, enc.yac, lambdaY, lumaWs)
      let lumaMode = if spJ < bestJ: lmB else: bestMode
      when defined(vp8encTrace):
        if mbx == 0 and mby == 0:
          echo "mb00 mode=", lumaMode, " j16=", bestJ, " jsplit=", spJ

      # chroma mode decision: RDO over the 4 modes with its own lambda.
      # The shared skip flag stays out of J (a ~2-bit term at most).
      var bestCm = cmDc
      var bestJc = Inf
      for cm in [cmDc, cmV, cmH, cmTm]:
        let (pu, pv) = rdoPredictChroma(cm, mbx, mby, enc.topBorderU,
          enc.leftBorderU, enc.topBorderV, enc.leftBorderV, chromaA,
          chromaB)
        let (qUc, qVc, zC) = rdoQuantChroma(pu, pv, srcU, srcV, enc.uvdc,
          enc.uvac)
        let cmVal = case cm
          of cmDc: 0
          of cmV: 1
          of cmH: 2
          of cmTm: 3
        var crate = treeCost(UvNodes, cmVal)
        var cssd: float64
        if zC:
          cssd = ssd8(srcU, pu) + ssd8(srcV, pv)
        else:
          crate += rdoRateChroma(qUc, qVc, tCxY, lCxY)
          let (ru, rv) = rdoReconChroma(pu, pv, qUc, qVc, mbx, mby,
            enc.topBorderU, enc.leftBorderU, enc.topBorderV,
            enc.leftBorderV, enc.uvdc, enc.uvac, chromaA,
            chromaB)
          cssd = ssd8(srcU, ru) + ssd8(srcV, rv)
        let cj = cssd + lambdaC * crate
        if cj < bestJc:
          bestJc = cj
          bestCm = cm

      # residual + quantize (trellis-refined; cx simulated exactly as the
      # bitstream section will derive it from the refined coeffs)
      var qY: array[16, array[16, int32]] # per 4x4 block, natural order
      var qY2: array[16, int32]
      var qU, qV: array[4, array[16, int32]]
      var allZero = true
      var tCxS = tCxY
      var lCxS = lCxY
      if lumaMode == lmB:
        for i in 0..<16:
          let bx = (i mod 4) * 4; let by = (i div 4) * 4
          fillBorderLuma(lumaWs, mbx, mby, mbw, enc.topBorderY,
            enc.leftBorderY)
          # predict the single block with chosen mode (interior blocks
          # see source-proxy neighbors, matching the search)
          for y in 0..<by + 4:
            for x in 0..<bx + 4:
              lumaWs[(1 + y) * 21 + 1 + x] = prox[y * 16 + x]
          case bmodes[i]
          of imTm: predictTmpred(lumaWs, 4, 1 + bx, 1 + by, 21)
          of imVe: predictBvepred(lumaWs, 1 + bx, 1 + by, 21)
          of imHe: predictBhepred(lumaWs, 1 + bx, 1 + by, 21)
          of imDc: predictBdcpred(lumaWs, 1 + bx, 1 + by, 21)
          of imLd: predictBldpred(lumaWs, 1 + bx, 1 + by, 21)
          of imRd: predictBrdpred(lumaWs, 1 + bx, 1 + by, 21)
          of imVr: predictBvrpred(lumaWs, 1 + bx, 1 + by, 21)
          of imVl: predictBvlpred(lumaWs, 1 + bx, 1 + by, 21)
          of imHd: predictBhdpred(lumaWs, 1 + bx, 1 + by, 21)
          of imHu: predictBhupred(lumaWs, 1 + bx, 1 + by, 21)
          var blk: array[16, float64]
          for y in 0..<4:
            for x in 0..<4:
              blk[y * 4 + x] = float64(int(prox[(by + y) * 16 + bx + x])) -
                float64(int(lumaWs[(1 + by + y) * 21 + 1 + bx + x]))
          let f = fdct4x4(blk)
          let sx = bx div 4; let sy = by div 4
          let cx = int(tCxS[sx + 1]) + int(lCxS[sy + 1])
          let (tq, tnz) = trellisBlk(f, enc.ydc, enc.yac, 3, cx, 0,
            trellisLambda(lambdaY))
          for k in 0..<16: qY[i][k] = tq[k]
          if tnz: allZero = false
          lCxS[sy + 1] = (if tnz: 1 else: 0)
          tCxS[sx + 1] = (if tnz: 1 else: 0)
      else:
        fillBorderLuma(lumaWs, mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        case lumaMode
        of lmV: predictVpred(lumaWs, 16, 1, 1, 21)
        of lmH: predictHpred(lumaWs, 16, 1, 1, 21)
        of lmTm: predictTmpred(lumaWs, 16, 1, 1, 21)
        of lmDc: predictDcpred(lumaWs, 16, 21, mby != 0, mbx != 0)
        else: discard
        var dcBlks: array[16, float64]
        for i in 0..<16:
          let bx = (i mod 4) * 4; let by = (i div 4) * 4
          var blk: array[16, float64]
          for y in 0..<4:
            for x in 0..<4:
              blk[y * 4 + x] = float64(int(srcY[(by + y) * 16 + bx + x])) -
                float64(int(lumaWs[(1 + by + y) * 21 + 1 + bx + x]))
          let f = fdct4x4(blk)
          dcBlks[i] = f[0]
          let sx = bx div 4; let sy = by div 4
          let cx = int(tCxS[sx + 1]) + int(lCxS[sy + 1])
          let (tq, tnz) = trellisBlk(f, enc.yac, enc.yac, 0, cx, 1,
            trellisLambda(lambdaY))
          for k in 1..<16: qY[i][k] = tq[k]
          if tnz: allZero = false
          lCxS[sy + 1] = (if tnz: 1 else: 0)
          tCxS[sx + 1] = (if tnz: 1 else: 0)
        let wht = fwht4x4(dcBlks)
        for k in 0..<16:
          let q = if k == 0: enc.y2dc else: enc.y2ac
          qY2[k] = quantizeCoeff(wht[k] * WhtGain, q)
          if qY2[k] != 0: allZero = false
      # write the winning chroma prediction into the workspaces so the
      # residual below is src minus prediction (not src minus zeros)
      fillBorderChroma(chromaA, mbx, mby, enc.topBorderU,
        enc.leftBorderU)
      fillBorderChroma(chromaB, mbx, mby, enc.topBorderV,
        enc.leftBorderV)
      var uws = chromaA
      var vws = chromaB
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
          let j = if ci == 0: 5 else: 7
          let sx = bx div 4; let sy = by div 4
          let cx = int(tCxS[sx + j]) + int(lCxS[sy + j])
          let (tq, tnz) = trellisBlk(f, enc.uvdc, enc.uvac, 2, cx, 0,
            trellisLambda(lambdaC))
          for k in 0..<16:
            if ci == 0: qU[i][k] = tq[k]
            else: qV[i][k] = tq[k]
          if tnz: allZero = false
          lCxS[sy + j] = (if tnz: 1 else: 0)
          tCxS[sx + j] = (if tnz: 1 else: 0)

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
          # The row below reads these as its above-context (mirrors the
          # decoder, which stores the converted mode into top.bpred --
          # cf. image-webp read_macroblock_header + top[mbx].bpred copy).
          # Missing this desyncs BpredNodes selection for any later
          # split MB in the same columns (latent since Phase 2; RDO
          # splits more often and exposed it).
          enc.topBpred[mbx][12 + i] = im
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
        # Skipped: no residuals; zero the nonzero-count contexts (mirrors
        # the decoder, which preserves slot 0 for split MBs since they
        # have no Y2 block -- cf. image-webp decode_frame_ else-branch).
        if lumaMode != lmB:
          enc.leftCx[0] = 0
          enc.topCx[mbx][0] = 0
        for i in 1..<9:
          enc.leftCx[i] = 0
          enc.topCx[mbx][i] = 0

      # reconstruction (mirrors intraPredictLuma/Chroma, unfiltered)
      if lumaMode == lmB:
        fillBorderLuma(lumaWs, mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        var ws = lumaWs
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
        fillBorderLuma(lumaWs, mbx, mby, mbw, enc.topBorderY,
          enc.leftBorderY)
        var ws = lumaWs
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
      fillBorderChroma(chromaA, mbx, mby, enc.topBorderU,
        enc.leftBorderU)
      fillBorderChroma(chromaB, mbx, mby, enc.topBorderV,
        enc.leftBorderV)
      var uwsF = chromaA
      var vwsF = chromaB
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
    # Row-boundary reset: reuse the existing seqs in place instead of
    # allocating fresh ones per row (steady-state zero-alloc).
    for i in 0..<17: enc.leftBorderY[i] = 129
    for i in 0..<9: enc.leftBorderU[i] = 129
    for i in 0..<9: enc.leftBorderV[i] = 129
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
  let mbw = (w + 15) div 16; let mbh = (h + 15) div 16

  # --- RGB -> YUV420, edge-padded to the MB grid ---
  # Single pass over the source: each padded position evaluates rgbToYuv601
  # once (previous code evaluated every pixel twice — once for Y, once for
  # the chroma box average). Y is stored with edge replication as before;
  # U/V accumulate the same available-sample sums and rounding.
  var ypl = newSeq[uint8](mbw * 16 * mbh * 16)
  var upl = newSeq[uint8](mbw * 8 * mbh * 8)
  var vpl = newSeq[uint8](mbw * 8 * mbh * 8)
  for y in 0..<(mbh * 8):
    for x in 0..<(mbw * 8):
      var su, sv, n = 0
      for dy in 0..1:
        let sy = y * 2 + dy
        let csy = min(sy, h - 1)
        for dx in 0..1:
          let sx = x * 2 + dx
          let csx = min(sx, w - 1)
          let p = img.pixels[csy * w + csx]
          let (yy, uu, vv) = rgbToYuv601(p.data[0], p.data[1], p.data[2])
          ypl[sy * mbw * 16 + sx] = yy
          if sx < w and sy < h:
            su += int(uu); sv += int(vv); inc n
      if n == 0:
        upl[y * mbw * 8 + x] = 128
        vpl[y * mbw * 8 + x] = 128
      else:
        upl[y * mbw * 8 + x] = uint8((su + n div 2) div n)
        vpl[y * mbw * 8 + x] = uint8((sv + n div 2) div n)

  # pass 1: default probs, count tokens
  resetTokTablesToDefaults()
  vp8LastNumUpdates = 0
  var hdr1 = initBoolEnc()
  var part1 = initBoolEnc()
  runVp8Pass(ypl, upl, vpl, w, h, qi, quality, hdr1, part1, false)
  # pass 2: install RD-beneficial updates, re-encode
  computeTokUpdates()
  rebuildCurTokTables()
  var hdr = initBoolEnc()
  var part = initBoolEnc()
  runVp8Pass(ypl, upl, vpl, w, h, qi, quality, hdr, part, true)
  # isolate globals (test hygiene: direct writeToken use sees defaults)
  resetTokTablesToDefaults()
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
