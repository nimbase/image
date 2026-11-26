# JPEG XS lossless encoder v1 — exact-roundtrip fixtures + Phase 8 start.
#
# Pure-Nim port companion to `jxsdec`. Reference interop: oxideav-jpegxs
# (MIT, (c) 2026 Karpeles Lab Inc.); this file is original Nim code
# under the workspace MIT license (holder "Nimbase Community").
#
# Scope: 8..16-bit gray (Cpih=0) + RGB(A) (Cpih=1, forward RCT),
# uniform depth, full-res, NL 1/1, single- or multi-slice, Cw=0,
# Q=R=0, D=0 (no-pred VLC), Dr=0, Deadzone, Fq=0, no NLT/CWD.
# Every emitted stream must decode bit-exactly (`q=0` lossless rule).
import std/math
import std/sequtils
import ./../error
import ./jxsdec

type
  JxsBitWriter = object
    buf: seq[uint8]
    bitPos: int

proc putBit(w: var JxsBitWriter, b: uint8) =
  if w.bitPos div 8 >= w.buf.len: w.buf.add(0)
  if b != 0:
    w.buf[w.bitPos div 8] =
      w.buf[w.bitPos div 8] or (0x80'u8 shr (w.bitPos mod 8))
  inc w.bitPos

proc putBits(w: var JxsBitWriter, v: uint32, n: int) =
  for k in countdown(n - 1, 0):
    w.putBit(uint8((v shr k) and 1))

proc putUnary(w: var JxsBitWriter, m: int) =
  for _ in 0..<m: w.putBit(1)
  w.putBit(0)

proc jxsAlign(w: var JxsBitWriter) =
  while w.bitPos mod 8 != 0: w.putBit(0)

func jxsBitLen(v: uint32): int =
  var x = v
  while x > 0:
    inc result
    x = x shr 1

# ---------------------------------------------------------------------------
# ISO/IEC 21122-1:2022 Annex H (informative) PSNR-optimized example (G,P)
# weight tables. Transcribed from the spec PDF (see the reference
# `annex_h_weights` for provenance). Order is band index b = Nc*β+i;
# subsampled 4:2:0 tables mark non-existent bands (`-*`) with G=255
# (filtered to existing-band emission order on return, like the
# reference); CFA tables carry both Cf columns, `cf` selects.
# Returns ok=false when (nc,cpih,sd,nlx,nly) is not tabulated.

const
  JxsH1_444_nly0: array[18, (uint8, uint8)] = [(3'u8, 6'u8), (2, 8),
    (2, 7), (2, 1), (1, 4), (1, 5), (2, 12), (1, 14), (1, 15), (1, 0),
    (0, 2), (0, 3), (1, 9), (0, 11), (0, 10), (1, 13), (0, 16), (0, 17)]
  JxsH2_444_nly1: array[24, (uint8, uint8)] = [(4'u8, 21'u8), (2, 1),
    (2, 0), (3, 15), (2, 19), (2, 18), (2, 5), (1, 9), (1, 8), (2, 14),
    (1, 17), (1, 16), (1, 2), (0, 4), (0, 3), (1, 7), (0, 13), (0, 11),
    (1, 6), (0, 12), (0, 10), (1, 20), (0, 23), (0, 22)]
  JxsH3_444_nly2: array[30, (uint8, uint8)] = [(4'u8, 12'u8), (3, 15),
    (3, 14), (3, 3), (2, 11), (2, 10), (3, 24), (2, 26), (2, 27),
    (2, 0), (1, 4), (1, 5), (2, 18), (1, 21), (1, 20), (2, 19),
    (1, 23), (1, 22), (1, 13), (0, 16), (0, 17), (1, 2), (0, 9),
    (0, 6), (1, 1), (0, 7), (0, 8), (1, 25), (0, 28), (0, 29)]
  JxsH4_422_nly0: array[18, (uint8, uint8)] = [(2'u8, 8'u8), (2, 7),
    (2, 6), (1, 5), (1, 3), (1, 4), (1, 13), (1, 12), (1, 14), (0, 1),
    (0, 0), (0, 2), (0, 9), (0, 11), (0, 10), (0, 16), (0, 15), (0, 17)]
  JxsH5_422_nly1: array[24, (uint8, uint8)] = [(2'u8, 0'u8), (2, 1),
    (2, 2), (2, 18), (2, 19), (2, 20), (1, 6), (1, 7), (1, 8),
    (1, 15), (1, 16), (1, 17), (0, 3), (0, 4), (0, 5), (0, 10),
    (0, 12), (0, 14), (0, 9), (0, 11), (0, 13), (0, 21), (0, 22),
    (0, 23)]
  JxsH6_422_nly2: array[30, (uint8, uint8)] = [(3'u8, 14'u8), (3, 13),
    (3, 12), (2, 9), (2, 11), (2, 10), (2, 25), (2, 24), (2, 26),
    (1, 0), (1, 1), (1, 2), (1, 19), (1, 20), (1, 18), (1, 23),
    (1, 22), (1, 21), (0, 17), (0, 15), (0, 16), (0, 4), (0, 8),
    (0, 5), (0, 3), (0, 6), (0, 7), (0, 28), (0, 27), (0, 29)]
  # G=255 marks the spec's `-*` (non-existent) slots, filtered out.
  JxsH7_420_nly1: array[24, (uint8, uint8)] = [(3'u8, 9'u8), (3, 16),
    (3, 15), (2, 7), (2, 13), (2, 12), (2, 17), (1, 3), (1, 2), (1, 6),
    (1, 11), (1, 10), (1, 14), (0, 1), (0, 0), (1, 19), (0, 5), (0, 4),
    (1, 18), (255, 255), (255, 255), (0, 8), (255, 255), (255, 255)]
  JxsH8_420_nly2: array[30, (uint8, uint8)] = [(3'u8, 0'u8), (3, 13),
    (3, 12), (3, 25), (2, 7), (2, 6), (2, 8), (2, 17), (2, 16), (2, 18),
    (1, 5), (1, 4), (1, 3), (1, 15), (1, 14), (1, 2), (255, 255),
    (255, 255), (0, 1), (255, 255), (255, 255), (1, 24), (1, 22),
    (1, 20), (1, 23), (1, 21), (1, 19), (0, 11), (0, 10), (0, 9)]
  JxsH9_cfa_nly0: array[19, (uint8, uint8, uint8, uint8)] = [
    (3'u8, 3'u8, 4'u8, 18'u8), (3, 17, 3, 17), (3, 16, 3, 16),
    (2, 1, 3, 13), (2, 15, 2, 12), (2, 14, 2, 11), (2, 11, 2, 5),
    (1, 7, 1, 4), (1, 6, 1, 3), (1, 0, 2, 14), (1, 13, 1, 10),
    (1, 12, 1, 9), (1, 10, 1, 6), (0, 5, 0, 1), (0, 4, 0, 0),
    (1, 18, 1, 15), (0, 9, 0, 9), (0, 8, 0, 7), (0, 2, 0, 2)]
  JxsH10_cfa_nly1: array[25, (uint8, uint8, uint8, uint8)] = [
    (4'u8, 20'u8, 4'u8, 13'u8), (3, 17, 3, 12), (3, 16, 3, 11),
    (3, 12, 3, 8), (2, 11, 2, 7), (2, 10, 2, 6), (2, 0, 3, 20),
    (2, 24, 2, 19), (2, 23, 2, 18), (2, 15, 2, 9), (1, 9, 1, 5),
    (1, 8, 1, 4), (1, 1, 2, 21), (1, 22, 1, 17), (1, 21, 1, 16),
    (1, 14, 1, 10), (0, 6, 0, 2), (0, 4, 0, 1), (1, 13, 1, 9),
    (0, 5, 1, 23), (0, 3, 1, 22), (0, 7, 1, 24), (0, 19, 0, 15),
    (0, 18, 0, 14), (0, 2, 0, 3)]
  JxsH11_cfa_nly2: array[31, (uint8, uint8, uint8, uint8)] = [
    (4'u8, 9'u8, 4'u8, 5'u8), (3, 8, 3, 4), (3, 7, 3, 3),
    (3, 0, 4, 28), (3, 30, 3, 27), (3, 29, 3, 26), (3, 20, 3, 18),
    (2, 19, 2, 17), (2, 18, 2, 16), (2, 1, 3, 30), (2, 28, 2, 23),
    (2, 27, 2, 22), (2, 24, 2, 19), (1, 16, 1, 14), (1, 14, 1, 13),
    (2, 23, 2, 12), (1, 15, 1, 11), (1, 13, 1, 10), (1, 17, 1, 9),
    (0, 11, 0, 8), (0, 10, 0, 7), (1, 22, 1, 15), (0, 6, 0, 2),
    (0, 4, 0, 1), (1, 21, 1, 0), (0, 5, 1, 25), (0, 3, 1, 24),
    (0, 12, 1, 29), (0, 26, 0, 21), (0, 25, 0, 20), (0, 2, 0, 6)]

proc jxsAnnexHWeights*(nc, cpih, sd, nlx, nly: uint8, cf: uint8,
    sx, sy: openArray[uint8]): tuple[ok: bool, weights: seq[(uint8, uint8)]] =
  ## Annex H PSNR-optimized example weights in existing-band emission
  ## order (the order the WGT loop consumes). `ok=false` when the
  ## configuration is not tabulated (needs nc=3/nlx=5, or CFA
  ## nc=4/sd=1/nlx=5).
  if cpih == 3 and sd == 1 and nc == 4 and nlx == 5:
    var is4444 = true
    for i in 0..<4:
      if sx[i] != 1 or sy[i] != 1: is4444 = false
    if not is4444: return (false, @[])
    if cf != 0 and cf != 3: return (false, @[])
    var res: seq[(uint8, uint8)] = @[]
    if nly == 0:
      for e in JxsH9_cfa_nly0:
        res.add(if cf == 0: (e[0], e[1]) else: (e[2], e[3]))
    elif nly == 1:
      for e in JxsH10_cfa_nly1:
        res.add(if cf == 0: (e[0], e[1]) else: (e[2], e[3]))
    elif nly == 2:
      for e in JxsH11_cfa_nly2:
        res.add(if cf == 0: (e[0], e[1]) else: (e[2], e[3]))
    else: return (false, @[])
    return (true, res)
  if nc != 3 or sd != 0 or nlx != 5: return (false, @[])
  var is444 = true
  for i in 0..<nc.int:
    if sx[i] != 1 or sy[i] != 1: is444 = false
  let chroma422 = nc == 3 and sx[0] == 1 and sy[0] == 1 and
    sx[1] == 2 and sy[1] == 1 and sx[2] == 2 and sy[2] == 1
  let chroma420 = nc == 3 and sx[0] == 1 and sy[0] == 1 and
    sx[1] == 2 and sy[1] == 2 and sx[2] == 2 and sy[2] == 2
  if cpih == 0 and (chroma422 or chroma420):
    var res: seq[(uint8, uint8)] = @[]
    if chroma422:
      if nly == 0:
        for e in JxsH4_422_nly0: res.add(e)
      elif nly == 1:
        for e in JxsH5_422_nly1: res.add(e)
      elif nly == 2:
        for e in JxsH6_422_nly2: res.add(e)
      else: return (false, @[])
    else:
      if nly == 1:
        for e in JxsH7_420_nly1:
          if e[0] != 255: res.add(e)
      elif nly == 2:
        for e in JxsH8_420_nly2:
          if e[0] != 255: res.add(e)
      else: return (false, @[]) # no 4:2:0 NLy=0 table
    return (true, res)
  if cpih != 1 or not is444: return (false, @[])
  var res: seq[(uint8, uint8)] = @[]
  if nly == 0:
    for e in JxsH1_444_nly0: res.add(e)
  elif nly == 1:
    for e in JxsH2_444_nly1: res.add(e)
  elif nly == 2:
    for e in JxsH3_444_nly2: res.add(e)
  else: return (false, @[])
  (true, res)

proc jxsEncodeLossless*(w, h: int, planesU: seq[seq[uint16]], bd: uint8,
    cpih: uint8, nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false,
    sampling: seq[(uint8, uint8)] = @[],
    bwAx: uint8 = 0, fqAx: uint8 = 0,
    nltKind: uint8 = 0, nltDco: int32 = 0,
    nltT1: uint32 = 0, nltT2: uint32 = 0, nltE: uint8 = 0,
    qpih: uint8 = 0, sd: uint8 = 0,
    weights: seq[(uint8, uint8)] = @[],
    stE1: uint8 = 0, stE2: uint8 = 0, stCt: uint8 = 0,
    stCf: uint8 = 0, bitDepths: seq[uint8] = @[],
    annexH: bool = false, qSlices: seq[uint8] = @[]): ImageResult[seq[uint8]] =
  ## Lossless (`q=0`) or lossy (`q=1..15`) bare codestream. `planesU`:
  ## Nc planes at native sampling in [0, 2^bds[i]). `bd` is the uniform
  ## depth shorthand (used when `bitDepths` is empty); pass `bitDepths`
  ## for mixed depths (fractional (Bw,Fq) paths only — Table A.8 needs
  ## uniform B[i] when Fq=0). `bwAx`/`fqAx` select the Table A.8 pair
  ## (0 = auto: integer, or NLT-implied); `nltKind` 1/2 emits the
  ## quadratic/extended NLT marker (Annex G.4/G.5).
  let nc = planesU.len
  if w < 2 or h < 2 or w > 65535 or h > 65535:
    return err[seq[uint8]](decodingError("jxs enc: bad dimensions"))
  var bds = newSeq[uint8](nc)
  if bitDepths.len > 0:
    if bitDepths.len != nc:
      return err[seq[uint8]](decodingError("jxs enc: bitDepths count"))
    for i in 0..<nc:
      if bitDepths[i] < 8 or bitDepths[i] > 16:
        return err[seq[uint8]](decodingError("jxs enc: bit depth 8..16"))
      bds[i] = bitDepths[i]
  else:
    if bd < 8 or bd > 16:
      return err[seq[uint8]](decodingError("jxs enc: bit depth 8..16"))
    for i in 0..<nc: bds[i] = bd
  var bMax: uint8 = bds[0]
  var bMixed = false
  for i in 1..<nc:
    if bds[i] != bds[0]: bMixed = true
    if bds[i] > bMax: bMax = bds[i]
  if nc < 1 or nc > 4:
    return err[seq[uint8]](decodingError("jxs enc: Nc 1..4"))
  if cpih == 1 and nc < 3:
    return err[seq[uint8]](decodingError("jxs enc: RCT needs Nc >= 3"))
  if cpih == 3 and nc < 4:
    return err[seq[uint8]](decodingError("jxs enc: Star-Tetrix needs Nc>=4"))
  if cpih != 0 and cpih != 1 and cpih != 3:
    return err[seq[uint8]](decodingError("jxs enc: Cpih 0/1/3 only"))
  if nlx < 1 or nlx > 8 or nly > nlx:
    return err[seq[uint8]](decodingError("jxs enc: NL range"))
  if q > 15:
    return err[seq[uint8]](decodingError("jxs enc: Q range"))
  var sx = newSeq[uint8](nc)
  var sy = newSeq[uint8](nc)
  for i in 0..<nc:
    sx[i] = 1
    sy[i] = 1
  if sampling.len > 0:
    if sampling.len != nc:
      return err[seq[uint8]](decodingError("jxs enc: sampling count"))
    for i in 0..<nc:
      if sampling[i][0] == 0 or sampling[i][1] == 0:
        return err[seq[uint8]](decodingError("jxs enc: sampling range"))
      sx[i] = sampling[i][0]
      sy[i] = sampling[i][1]
  if cpih == 1:
    for i in 0..<min(3, nc):
      if sx[i] != 1 or sy[i] != 1:
        return err[seq[uint8]](decodingError("jxs enc: RCT subsampled"))
  if cpih == 3:
    for i in 0..<4:
      if sx[i] != 1 or sy[i] != 1:
        return err[seq[uint8]](decodingError("jxs enc: Star-Tetrix inputs"))
    if stE1 > 3 or stE2 > 3:
      return err[seq[uint8]](decodingError("jxs enc: Star-Tetrix e1/e2"))
    if stCt > 1:
      return err[seq[uint8]](decodingError("jxs enc: Star-Tetrix Ct"))
    if stCf != 0 and stCf != 3:
      return err[seq[uint8]](decodingError("jxs enc: Star-Tetrix Cf"))
  var maxSx: uint8 = 1
  var maxSy: uint8 = 1
  for i in 0..<nc:
    if sx[i] > maxSx: maxSx = sx[i]
    if sy[i] > maxSy: maxSy = sy[i]
  if w < maxSx.int * (1 shl nlx.int) or h < maxSy.int * (1 shl nly.int):
    return err[seq[uint8]](decodingError("jxs enc: below Table 11 floor"))
  var cw = newSeq[int](nc)
  var ch = newSeq[int](nc)
  for i in 0..<nc:
    cw[i] = (w + sx[i].int - 1) div sx[i].int
    ch[i] = (h + sy[i].int - 1) div sy[i].int
    if planesU[i].len != cw[i] * ch[i]:
      return err[seq[uint8]](decodingError("jxs enc: plane size"))
    for u in planesU[i]:
      if u.uint32 >= (1'u32 shl bds[i].int):
        return err[seq[uint8]](decodingError("jxs enc: sample range"))
  if bMixed and fqAx == 0 and bwAx == 0 and nltKind == 0:
    # Table A.8: Fq=0 (the auto path without NLT) needs uniform B[i].
    # Mixed depths need an explicit fractional pair, e.g. (20,8).
    return err[seq[uint8]](decodingError("jxs enc: mixed depths need Fq!=0"))
  let bw: uint8 =
    if bwAx != 0: bwAx
    elif nltKind != 0 and bMax > 8: 20
    elif nltKind != 0: 18
    elif bMixed: bMax
    else: bds[0]
  let fq: uint8 =
    if fqAx != 0 or bwAx != 0: fqAx
    elif nltKind != 0 and bMax == 8: 6
    elif nltKind != 0: 8
    else: 0
  if bMixed and fq == 0:
    return err[seq[uint8]](decodingError("jxs enc: mixed depths need Fq!=0"))
  if fq != 0 and fq != 6 and fq != 8:
    return err[seq[uint8]](decodingError("jxs enc: Fq must be 0/6/8"))
  if qpih > 1:
    return err[seq[uint8]](decodingError("jxs enc: Qpih must be 0/1"))
  if sd > 0:
    if nc <= 3:
      return err[seq[uint8]](decodingError("jxs enc: Sd needs Nc > 3"))
    if sd.uint8 >= nc.uint8:
      return err[seq[uint8]](decodingError("jxs enc: Sd must be < Nc"))
    for i in (nc - sd.int)..<nc:
      if sx[i] != 1 or sy[i] != 1:
        return err[seq[uint8]](decodingError("jxs enc: Sd comp sampling"))
    if cpih == 1 and nc - sd.int < 3:
      return err[seq[uint8]](decodingError("jxs enc: RCT needs Nc-Sd >= 3"))
  if nltKind == 2:
    if nltT1 == 0 or nltT2 == 0 or nltT2 <= nltT1:
      return err[seq[uint8]](decodingError("jxs enc: NLT needs 0<T1<T2"))
    if nltE < 1 or nltE > 4:
      return err[seq[uint8]](decodingError("jxs enc: NLT E range 1..4"))
    if nltT1 >= (1'u32 shl bw.int) or nltT2 >= (1'u32 shl bw.int):
      return err[seq[uint8]](decodingError("jxs enc: NLT thresholds"))
  if nltKind == 1 and (nltDco < -(1 shl 15) or nltDco > (1 shl 15) - 1):
    return err[seq[uint8]](decodingError("jxs enc: NLT DCO range"))
  # forward RCT for colour
  var planes = newSeq[seq[int]](nc)
  for i in 0..<nc:
    planes[i] = newSeq[int](cw[i] * ch[i])
    for x in 0..<cw[i]*ch[i]: planes[i][x] = planesU[i][x].int
  if nltKind == 0:
    # Annex G.3 inverse then F.4: level shift on the image samples FIRST
    # (a uniform shift does not commute with the RCT: Cb/Cr differences
    # would inherit a spurious bias), then the forward RCT, then the DWT.
    let dc = 1 shl (bw.int - 1)
    for i in 0..<nc:
      let ups = bw.int - bds[i].int
      for x in 0..<cw[i]*ch[i]:
        planes[i][x] = (planes[i][x] shl ups) - dc
  else:
    # Annex G.4/G.5 forward: per-sample map into [0, 2^Bw-1], then -dc.
    let bwMax = (1 shl bw.int) - 1
    let dc = 1 shl (bw.int - 1)
    var lut = newSeq[int](bwMax + 1) # extended reverse map, built lazily
    var lutBd: uint8 = 0 # depth the LUT was built for
    var lutDone = false
    for i in 0..<nc:
      let bMaxI = (1 shl bds[i].int) - 1
      for x in 0..<cw[i]*ch[i]:
        let smp = min(max(planes[i][x], 0), bMaxI)
        var y: int
        if nltKind == 1:
          if smp == 0: y = 0
          else:
            y = int(sqrt(smp.float / bMaxI.float) * bwMax.float + 0.5)
          y = min(max(y + nltDco.int, 0), bwMax)
        else:
          if not lutDone or lutBd != bds[i]:
            var prev = -1
            for wcode in 0..bwMax:
              let o = jxsNltExt(wcode - dc, bw, bds[i], nltT1, nltT2, nltE)
              for v in (prev + 1)..o:
                if v <= bMaxI: lut[v] = wcode
              prev = o
              if prev >= bMaxI: break
            lutDone = true
            lutBd = bds[i]
          y = lut[smp]
        planes[i][x] = y - dc
  if cpih == 1:
    jxsForwardRct(planes)
  elif cpih == 3:
    let fR = jxsForwardStarTetrix(planes, w, h, stE1, stE2, stCt.int,
      stCf.int)
    if not fR.ok: return err[seq[uint8]](fR.err)
  # forward cascade per component at its effective depth;
  # suppressed (Sd) tail components bypass the DWT (raw-coded).
  var picBands = newSeq[seq[seq[int]]](nc)
  for i in 0..<nc:
    if sd > 0 and i >= nc - sd.int:
      picBands[i] = @[planes[i]]
      continue
    let lg = jxsLog2Sy(sy[i])
    if lg < 0:
      return err[seq[uint8]](decodingError("jxs enc: bad sampling"))
    let nlyI = satSub8(nly, lg.uint8)
    let fR = jxsForwardCascade(cw[i], ch[i], nlx, nlyI, planes[i])
    if not fR.ok: return err[seq[uint8]](fR.err)
    picBands[i] = fR.value
  # E.3 forward: exact inverse of the decoder's `c << Fq`.
  if fq != 0:
    let rr = (1 shl fq.int) shr 1
    for i in 0..<nc:
      for b in 0..<picBands[i].len:
        for k in 0..<picBands[i][b].len:
          let t = picBands[i][b][k]
          picBands[i][b][k] =
            if t >= 0: (t + rr) shr fq.int
            else: -((-t + rr) shr fq.int)
  # picture header + plan (WGT zeros; existing bands only)
  var pih = JxsPih(lcod: 0, ppih: 0, plev: 0, wf: w.uint16,
    hf: h.uint16, cw: 0, hsl: 1, nc: nc.uint8, ng: 4, ss: 8, bw: bw,
    fq: fq, br: 4, fslc: 0, ppoc: 0, cpih: cpih, nlx: nlx, nly: nly,
    lh: 0, rl: 0, qpih: qpih, fs: 0, rm: 0)
  let nBeta = jxsNBeta(nlx, nly).int
  var comps: seq[JxsComp] = @[]
  for i in 0..<nc:
    comps.add(JxsComp(bitDepth: bds[i], sx: sx[i], sy: sy[i]))
  # per-band (G,P): default zeros, caller-supplied Annex-H-style
  # weights indexed by flat band id b = nDec*β+i (then Sd tails), or
  # the Annex H example tables (`annexH=true`, emission order mapped
  # back onto the flat ids here).
  let nDec = nc - sd.int
  let nBandsTot = nDec * nBeta + sd.int
  if weights.len != 0 and weights.len != nBandsTot:
    return err[seq[uint8]](decodingError("jxs enc: weights count"))
  if annexH and weights.len > 0:
    return err[seq[uint8]](decodingError("jxs enc: annexH with weights"))
  var bandG = newSeq[uint8](nBandsTot)
  var bandP = newSeq[uint8](nBandsTot)
  for b in 0..<nBandsTot:
    if weights.len > 0:
      if weights[b][0] > 15:
        return err[seq[uint8]](decodingError("jxs enc: WGT gain cap"))
      bandG[b] = weights[b][0]
      bandP[b] = weights[b][1]
  if annexH:
    let ahR = jxsAnnexHWeights(nc.uint8, cpih, sd, nlx, nly, stCf,
      sx, sy)
    if not ahR.ok:
      return err[seq[uint8]](decodingError(
        "jxs enc: no Annex H table for this configuration"))
    var k = 0
    for beta in 0..<nBeta:
      for i in 0..<nDec:
        if jxsPicBetaToLocal(beta.uint32, nlx, nly, sy[i]) >= 0:
          if k >= ahR.weights.len:
            return err[seq[uint8]](decodingError(
              "jxs enc: Annex H table short"))
          let b = nDec * beta + i
          bandG[b] = ahR.weights[k][0]
          bandP[b] = ahR.weights[k][1]
          inc k
    for kk in 0..<sd.int:
      if k >= ahR.weights.len:
        return err[seq[uint8]](decodingError("jxs enc: Annex H table short"))
      let b = nDec * nBeta + kk
      bandG[b] = ahR.weights[k][0]
      bandP[b] = ahR.weights[k][1]
      inc k
    if k != ahR.weights.len:
      return err[seq[uint8]](decodingError("jxs enc: Annex H table long"))
  var wgtZ: seq[uint8] = @[]
  for beta in 0..<nBeta:
    for i in 0..<nDec:
      if jxsPicBetaToLocal(beta.uint32, nlx, nly, sy[i]) >= 0:
        let b = nDec * beta + i
        wgtZ.add(bandG[b])
        wgtZ.add(bandP[b])
  for k in 0..<sd.int:
    let b = nDec * nBeta + k
    wgtZ.add(bandG[b])
    wgtZ.add(bandP[b])
  # per-band truncation T[p,b] = clamp(Q-G-(P<R?1:0), 0, 15), R=0.
  # Uniform-Q uses one table; `qSlices` gives one Q per slice (the
  # precinct header carries Q[p], so slices quantize independently for
  # CBR rate allocation). Tables are built after the plan (slice count
  # known there); Br below takes the global max.
  let useShort = w * nc < 32752
  let planR = jxsBuildPlan(pih, comps, wgtZ, sd)
  if not planR.ok: return err[seq[uint8]](planR.err)
  var plan = planR.value
  if multiSlice:
    # rebuild with Hsl=1 (one precinct row per slice)
    pih.hsl = 1
  else:
    pih.hsl = plan.npY.uint16
  let planR2 = jxsBuildPlan(pih, comps, wgtZ, sd)
  if not planR2.ok: return err[seq[uint8]](planR2.err)
  plan = planR2.value
  # per-slice Q vector (uniform `q` when `qSlices` is empty).
  var sliceQ = newSeq[uint8](plan.slices.len)
  if qSlices.len == 0:
    for t in 0..<sliceQ.len: sliceQ[t] = q
  else:
    if qSlices.len != plan.slices.len:
      return err[seq[uint8]](decodingError("jxs enc: qSlices count"))
    for t in 0..<sliceQ.len:
      if qSlices[t] > 15:
        return err[seq[uint8]](decodingError("jxs enc: Q range"))
      sliceQ[t] = qSlices[t]
  var sliceTrunc = newSeq[seq[uint8]](plan.slices.len)
  for t in 0..<plan.slices.len:
    sliceTrunc[t] = newSeq[uint8](nBandsTot)
    for b in 0..<nBandsTot:
      sliceTrunc[t][b] = jxsTruncT(sliceQ[t], bandG[b], bandP[b], 0)
  # max emitted bitplane count sets Br (VLC bound min(2^Br-1,31));
  # T is per (slice, picture band), coefficients per local band.
  var maxM = 0
  for t in 0..<plan.slices.len:
    for i in 0..<nDec:
      for betaPic in 0..<nBeta:
        let b = nDec * betaPic + i
        let loc = jxsPicBetaToLocal(betaPic.uint32, nlx, nly, sy[i])
        if loc < 0: continue
        for v in picBands[i][loc]:
          let m = jxsBitLen(if v < 0: (-v).uint32 else: v.uint32)
          let me = max(sliceTrunc[t][b].int, m)
          if me > maxM: maxM = me
    for k in 0..<sd.int:
      let b = nDec * nBeta + k
      for v in picBands[nDec + k][0]:
        let m = jxsBitLen(if v < 0: (-v).uint32 else: v.uint32)
        let me = max(sliceTrunc[t][b].int, m)
        if me > maxM: maxM = me
  if maxM > 31:
    return err[seq[uint8]](decodingError("jxs enc: M exceeds 31"))
  var br: uint8 = 4
  if maxM > 15:
    br = jxsBitLen(maxM.uint32).uint8 # 2^Br-1 >= maxM
  pih.br = br
  # emit
  var outP: seq[uint8] = @[]
  template marker(m: uint16) =
    outP.add(uint8(m shr 8))
    outP.add(uint8(m and 0xFF))
  template seg(m: uint16, body: seq[uint8]) =
    marker(m)
    let ll = body.len + 2
    outP.add(uint8(ll shr 8))
    outP.add(uint8(ll and 0xFF))
    for bb in body: outP.add(bb)
  marker(JxsSoc)
  if nltKind == 1:
    seg(JxsMkrCap, @[0x20'u8]) # bit 2: quadratic NLT
  elif nltKind == 2:
    seg(JxsMkrCap, @[0x10'u8]) # bit 3: extended NLT
  else:
    seg(JxsMkrCap, @[])
  var pihB: seq[uint8] = @[]
  pihB.add(@[0'u8, 0, 0, 0]) # Lcod VBR
  pihB.add(@[0'u8, 0]) # Ppih
  pihB.add(@[0'u8, 0]) # Plev
  pihB.add(uint8(w shr 8)); pihB.add(uint8(w and 0xFF))
  pihB.add(uint8(h shr 8)); pihB.add(uint8(h and 0xFF))
  pihB.add(@[0'u8, 0]) # Cw
  pihB.add(uint8(pih.hsl shr 8)); pihB.add(uint8(pih.hsl and 0xFF))
  pihB.add(pih.nc); pihB.add(4); pihB.add(8); pihB.add(bw)
  pihB.add((fq shl 4) or br) # Fq | Br
  pihB.add(cpih) # Fslc/Ppoc/Cpih
  pihB.add((nlx shl 4) or nly) # NLx/NLy
  pihB.add(qpih shl 4) # Lh/Rl/Qpih/Fs/Rm (rest zero)
  seg(JxsMkrPih, pihB)
  var cdtB: seq[uint8] = @[]
  for i in 0..<nc:
    cdtB.add(bds[i])
    cdtB.add((sx[i] shl 4) or sy[i])
  seg(JxsMkrCdt, cdtB)
  seg(JxsMkrWgt, wgtZ)
  if cpih == 3:
    seg(JxsMkrCts, @[stCf, uint8((stE1 shl 4) or stE2)])
    var crgB: seq[uint8] = @[]
    # Table F.9 super-pixel placements per Ct (RGGB / GRBG).
    let pats =
      if stCt == 0: [(0'u16, 0'u16), (32768'u16, 0'u16),
        (0'u16, 32768'u16), (32768'u16, 32768'u16)]
      else: [(32768'u16, 0'u16), (0'u16, 0'u16),
        (32768'u16, 32768'u16), (0'u16, 32768'u16)]
    for i in 0..<nc:
      let (qx, qy) =
        if i < 4: pats[i]
        else: (0'u16, 0'u16) # suppressed tail: position-free
      crgB.add(uint8(qx shr 8)); crgB.add(uint8(qx and 0xFF))
      crgB.add(uint8(qy shr 8)); crgB.add(uint8(qy and 0xFF))
    seg(JxsMkrCrg, crgB)
  if nltKind == 1:
    let dcoU = (if nltDco < 0: (1 shl 15) or (-nltDco) else: nltDco) and 0xFFFF
    seg(JxsMkrNlt, @[1'u8, uint8(dcoU shr 8), uint8(dcoU and 0xFF)])
  elif nltKind == 2:
    var nltB = @[2'u8]
    for v in [nltT1, nltT2]:
      nltB.add(uint8(v shr 24)); nltB.add(uint8((v shr 16) and 0xFF))
      nltB.add(uint8((v shr 8) and 0xFF)); nltB.add(uint8(v and 0xFF))
    nltB.add(nltE)
    seg(JxsMkrNlt, nltB)
  if sd > 0:
    seg(JxsMkrCwd, @[sd])
  for si, sp in plan.slices:
    var slhB = @[uint8(sp.t shr 8), uint8(sp.t and 0xFF)]
    seg(JxsMkrSlh, slhB)
    for prec in sp.precincts:
      let py = (prec.p div plan.npX).int
      # band segments from picture buffers
      var segs = newSeq[seq[int]](prec.bands.len)
      var segLines = newSeq[int](prec.bands.len)
      for b, bg in prec.bands:
        if not bg.exists:
          segs[b] = @[]
          continue
        let i = prec.bandComp[b].int
        let loc = prec.bandLocalBeta[b].int
        let isSupp = sd > 0 and i >= nc - sd.int
        var picBW = 0
        var powH = 1
        if isSupp:
          # raw-coded tail: full-width plane, picture-height rows
          picBW = cw[i]
          powH = if nly == 0: 1 else: 1 shl nly.int
        else:
          let lgI = jxsLog2Sy(sy[i])
          if lgI < 0:
            return err[seq[uint8]](decodingError("jxs enc: bad sampling"))
          let nlyI = satSub8(nly, lgI.uint8)
          let (dxL, dyL, txL, tyL) = jxsBetaLevels(loc.uint32, nlx, nlyI)
          picBW = jxsBandDims(cw[i], ch[i], dxL, dyL, txL, tyL).w
          powH =
            if nlyI == 0 or dyL >= nlyI: 1
            else: 1 shl (nlyI.int - dyL.int)
        let rowOff = py * powH
        let lines = (bg.l1 - bg.l0).int
        segLines[b] = lines
        var sg = newSeq[int](lines * bg.wpb.int)
        for li in 0..<lines:
          for x in 0..<bg.wpb.int:
            sg[li * bg.wpb.int + x] =
              picBands[i][loc][(rowOff + li) * picBW + x]
        segs[b] = move(sg)
      # M table per (band, line, group): emitted M floors at the
      # band's T (lossy: dropping high planes is illegal, T drops low).
      var mTab = newSeq[seq[seq[uint8]]](prec.bands.len)
      for b, bg in prec.bands:
        if not bg.exists or bg.wpb == 0:
          mTab[b] = @[]
          continue
        let tB = sliceTrunc[si][b].int
        let ncg = jxsNcg(bg.wpb, 4).int
        var ml = newSeq[seq[uint8]](segLines[b])
        for li in 0..<segLines[b]:
          var mm = newSeq[uint8](ncg)
          for g in 0..<ncg:
            var mxv: uint32 = 0
            for k in 0..<4:
              let x = g * 4 + k
              if x < bg.wpb.int:
                let v = segs[b][li * bg.wpb.int + x]
                let a = if v < 0: (-v).uint32 else: v.uint32
                if a > mxv: mxv = a
            mm[g] = max(tB.uint8, jxsBitLen(mxv).uint8)
          ml[li] = move(mm)
        mTab[b] = move(ml)
      # precinct body: reserve Lprc, then headers + packets
      let precStart = outP.len
      outP.add(@[0'u8, 0, 0]) # Lprc placeholder
      outP.add(sliceQ[si]) # Q[p]
      outP.add(0) # R
      var dW: JxsBitWriter
      for bg in prec.bands:
        if bg.exists:
          dW.putBits(0, 2) # D=0
      jxsAlign(dW)
      for bb in dW.buf: outP.add(bb)
      let bodyStart = outP.len # Lprc counts entropy after this header
      for layout in prec.packets:
        if layout.len == 0: continue
        var cntW: JxsBitWriter
        for e in layout:
          let bi = e.band.int
          let tBi = sliceTrunc[si][bi].int
          # line index within this precinct's segment
          let lix = (e.line - prec.bands[bi].l0).int
          for g in 0..<mTab[bi][lix].len:
            cntW.putUnary(mTab[bi][lix][g].int - tBi) # theta=0
        jxsAlign(cntW)
        var datW: JxsBitWriter
        for e in layout:
          let bi = e.band.int
          let tBi = sliceTrunc[si][bi].int
          let bg = prec.bands[bi]
          let li = (e.line - bg.l0).int
          for g in 0..<mTab[bi][li].len:
            let m = mTab[bi][li][g].int
            if m > tBi:
              let base = li * bg.wpb.int + g * 4
              # Table C.8: Fs=0 emits all Ng sign bits per group,
              # even past the band edge (0 there).
              for k in 0..<4:
                let x = g * 4 + k
                var sgn: uint8 = 0
                if x < bg.wpb.int and segs[bi][base + k] < 0: sgn = 1
                datW.putBit(sgn)
              for plane in countdown(m - 1, tBi):
                for k in 0..<4:
                  let x = g * 4 + k
                  var bit: uint8 = 0
                  if x < bg.wpb.int:
                    let v = segs[bi][base + k]
                    let a = if v < 0: (-v).uint32 else: v.uint32
                    bit = uint8((a shr plane) and 1)
                  datW.putBit(bit)
        jxsAlign(datW)
        # packet header: short (5B) or long (7B) Table C.3 form
        if useShort:
          if datW.buf.len >= (1 shl 15) or cntW.buf.len >= (1 shl 13):
            return err[seq[uint8]](decodingError("jxs enc: packet too big"))
          var hdr: JxsBitWriter
          hdr.putBits(0, 1)
          hdr.putBits(datW.buf.len.uint32, 15)
          hdr.putBits(cntW.buf.len.uint32, 13)
          hdr.putBits(0, 11)
          for bb in hdr.buf: outP.add(bb)
        else:
          if datW.buf.len >= (1 shl 20) or cntW.buf.len >= (1 shl 20):
            return err[seq[uint8]](decodingError("jxs enc: packet too big"))
          var hdr: JxsBitWriter
          hdr.putBits(0, 1)
          hdr.putBits(datW.buf.len.uint32, 20)
          hdr.putBits(cntW.buf.len.uint32, 20)
          hdr.putBits(0, 15)
          for bb in hdr.buf: outP.add(bb)
        for bb in cntW.buf: outP.add(bb)
        for bb in datW.buf: outP.add(bb)
      let lprc = outP.len - bodyStart
      if lprc < 1 or lprc > (1 shl 20) - 1:
        return err[seq[uint8]](decodingError("jxs enc: Lprc range"))
      outP[precStart] = uint8(lprc shr 16)
      outP[precStart+1] = uint8((lprc shr 8) and 0xFF)
      outP[precStart+2] = uint8(lprc and 0xFF)
  marker(JxsEoc)
  ok(outP)

proc encodeJxsGray8*(w, h: int, px: openArray[uint8], nlx: uint8 = 1,
    nly: uint8 = 1, q: uint8 = 0, multiSlice = false,
    qpih: uint8 = 0): ImageResult[seq[uint8]] =
  ## Gray still, 8-bit; `q=0` lossless, `q=1..15` lossy (precinct cut);
  ## `qpih` selects the deadzone (0) or uniform (1) inverse quantizer.
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, nlx, nly, q, multiSlice,
    @[], 0, 0, 0, 0, 0, 0, 0, qpih)

proc encodeJxsGray16*(w, h: int, px: openArray[uint16], bd: uint8,
    nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Gray still at `bd` bits (8..16); `q=0` lossless.
  jxsEncodeLossless(w, h, @[@px], bd, 0, nlx, nly, q, multiSlice)

proc encodeJxsRgb8*(w, h: int, rgb: openArray[uint8], nlx: uint8 = 1,
    nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false): ImageResult[seq[uint8]] =
  ## RGB still, 8-bit (forward RCT); `q=0` lossless.
  if rgb.len != w * h * 3:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var r = newSeq[uint16](w * h)
  var g = newSeq[uint16](w * h)
  var b = newSeq[uint16](w * h)
  for i in 0..<w*h:
    r[i] = rgb[3*i]
    g[i] = rgb[3*i+1]
    b[i] = rgb[3*i+2]
  jxsEncodeLossless(w, h, @[r, g, b], 8, 1, nlx, nly, q, multiSlice)

proc encodeJxsHighPrec8*(w, h: int, px: openArray[uint8],
    q: uint8, multiSlice = false): ImageResult[seq[uint8]] =
  ## Gray still through the (Bw=20, Fq=8) high-precision path: 8
  ## fractional bits through the transform, lossy via `q`.
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, 1, 1, q, multiSlice, @[], 20, 8)

proc encodeJxsCfa8*(w, h: int, r, g1, g2, b: openArray[uint8],
    e1, e2, ct, cf: uint8, nlx: uint8 = 1, nly: uint8 = 1,
    q: uint8 = 0, multiSlice = false): ImageResult[seq[uint8]] =
  ## 4-component CFA still (Star-Tetrix, Cpih=3) in [R, G1, G2, B]
  ## plane order; `q=0` lossless. Emits CTS + CRG markers.
  if r.len != w * h or g1.len != w * h or g2.len != w * h or
      b.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pr = newSeq[uint16](w * h)
  var pg1 = newSeq[uint16](w * h)
  var pg2 = newSeq[uint16](w * h)
  var pb = newSeq[uint16](w * h)
  for i in 0..<w*h:
    pr[i] = r[i]
    pg1[i] = g1[i]
    pg2[i] = g2[i]
    pb[i] = b[i]
  jxsEncodeLossless(w, h, @[pr, pg1, pg2, pb], 8, 3, nlx, nly, q,
    multiSlice, @[], 0, 0, 0, 0, 0, 0, 0, 0, 0, @[], e1, e2, ct, cf)

proc encodeJxsNltQuad8*(w, h: int, px: openArray[uint8], dco: int32 = 0,
    nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Gray still with quadratic NLT (Tnlt=1, Bw=18): forward
  ## `y = round(sqrt(x/255) * (2^18-1)) + dco`. Roundtrips within a
  ## few LSB (sqrt rounding), not bit-exact.
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, nlx, nly, q, multiSlice, @[],
    0, 0, 1, dco)

proc encodeJxsNltExt8*(w, h: int, px: openArray[uint8], t1, t2: uint32,
    e: uint8, nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Gray still with extended NLT (Tnlt=2, Bw=18): forward reverse-LUT
  ## pre-distortion. Roundtrips within a few LSB, not bit-exact.
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, nlx, nly, q, multiSlice, @[],
    0, 0, 2, 0, t1, t2, e)

proc encodeJxsYuv8*(w, h: int, y, cb, cr: openArray[uint8],
    sxC, syC: uint8, nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false): ImageResult[seq[uint8]] =  ## Planar YCbCr still, 8-bit, chroma sampling (sxC, syC) ∈ {1,2}²
  ## minus (1,2); `q=0` lossless.
  if sxC notin [1'u8, 2] or syC notin [1'u8, 2] or (sxC == 1 and syC == 2):
    return err[seq[uint8]](decodingError("jxs enc: chroma sampling"))
  let cwch = (w + sxC.int - 1) div sxC.int
  let chch = (h + syC.int - 1) div syC.int
  if y.len != w * h or cb.len != cwch * chch or cr.len != cwch * chch:
    return err[seq[uint8]](decodingError("jxs enc: plane size"))
  var py = newSeq[uint16](w * h)
  var pcb = newSeq[uint16](cwch * chch)
  var pcr = newSeq[uint16](cwch * chch)
  for i in 0..<py.len: py[i] = y[i]
  for i in 0..<pcb.len: pcb[i] = cb[i]
  for i in 0..<pcr.len: pcr[i] = cr[i]
  jxsEncodeLossless(w, h, @[py, pcb, pcr], 8, 0, nlx, nly, q, multiSlice,
    @[(1'u8, 1'u8), (sxC, syC), (sxC, syC)])

# ---------------------------------------------------------------------------
# Encoder-side conformance signalling + CBR rate allocation.
#
# Mirrors the reference `signalling` module: the picture header's
# Lcod/Ppih/Plev fields live at fixed offsets in the PIH body and are
# patched in place, with each claim re-verified through the same gates
# the decoder runs (so the encoder cannot emit a false declaration).
# CBR pads with vendor-specific COM segments (Tcom=0x8000, zero Dcom)
# before the first SLH, which the decoder skips as unknown extensions.

const
  JxsTcomVendor*: uint16 = 0x8000'u16
  JxsComMinSeg* = 6
  JxsComMaxSeg* = 2 + 0xFFFF

proc jxsPihBodyOffset*(buf: openArray[uint8]): ImageResult[int] =
  ## Byte offset of the PIH body (first Lcod byte) by marker walk.
  if buf.len < 4 or buf[0] != 0xFF or buf[1] != 0x10:
    return err[int](decodingError("jxs: buffer does not start with SOC"))
  var pos = 2
  while true:
    if pos + 2 > buf.len:
      return err[int](decodingError("jxs: marker chain ended before PIH"))
    if buf[pos] != 0xFF:
      return err[int](decodingError("jxs: expected marker"))
    let mk = buf[pos+1]
    if mk == 0x12:
      if pos + 4 > buf.len:
        return err[int](decodingError("jxs: PIH truncated"))
      let lpih = (buf[pos+2].int shl 8) or buf[pos+3].int
      if lpih != 26 or pos + 2 + lpih > buf.len:
        return err[int](decodingError("jxs: bad PIH length"))
      return ok(pos + 4)
    if mk == 0x20 or mk == 0x11:
      return err[int](decodingError("jxs: reached SLH/EOC before PIH"))
    if pos + 4 > buf.len:
      return err[int](decodingError("jxs: segment truncated"))
    let ln = (buf[pos+2].int shl 8) or buf[pos+3].int
    if ln < 2 or pos + 2 + ln > buf.len:
      return err[int](decodingError("jxs: bad segment length"))
    pos += 2 + ln

proc jxsFirstSlhOffset*(buf: openArray[uint8]): ImageResult[int] =
  ## Byte offset of the first SLH marker (COM insertion point).
  if buf.len < 4 or buf[0] != 0xFF or buf[1] != 0x10:
    return err[int](decodingError("jxs: buffer does not start with SOC"))
  var pos = 2
  while true:
    if pos + 2 > buf.len:
      return err[int](decodingError("jxs: no SLH marker"))
    if buf[pos] != 0xFF:
      return err[int](decodingError("jxs: expected marker"))
    let mk = buf[pos+1]
    if mk == 0x20: return ok(pos)
    if mk == 0x11:
      return err[int](decodingError("jxs: reached EOC before SLH"))
    if pos + 4 > buf.len:
      return err[int](decodingError("jxs: segment truncated"))
    let ln = (buf[pos+2].int shl 8) or buf[pos+3].int
    if ln < 2 or pos + 2 + ln > buf.len:
      return err[int](decodingError("jxs: bad segment length"))
    pos += 2 + ln

proc jxsPatchAndVerify*(buf: var seq[uint8], at: int,
    bytes: openArray[uint8]): ImageResult[bool] =
  ## Write `bytes` at `at`, re-parse and re-run the matching gate;
  ## restore on failure.
  if at < 0 or at + bytes.len > buf.len:
    return err[bool](decodingError("jxs: patch out of range"))
  let save = buf.toSeq()
  for i in 0..<bytes.len: buf[at+i] = bytes[i]
  let hR = parseJxsCodestream(buf)
  if not hR.ok:
    buf = save
    return err[bool](hR.err)
  ok(true)

proc jxsDeclareProfile*(buf: var seq[uint8],
    ppih: uint16): ImageResult[bool] =
  ## Write Ppih (PIH body +4) and verify via `jxsCheckProfile`.
  let bR = jxsPihBodyOffset(buf)
  if not bR.ok: return err[bool](bR.err)
  let at = bR.value + 4
  let bytes = @[uint8(ppih shr 8), uint8(ppih and 0xFF)]
  let save = buf.toSeq()
  for i in 0..<2: buf[at+i] = bytes[i]
  let hR = parseJxsCodestream(buf)
  if not hR.ok:
    buf = save
    return err[bool](hR.err)
  let gR = jxsCheckProfile(hR.value)
  if not gR.ok:
    buf = save
    return err[bool](gR.err)
  ok(true)

proc jxsDeclareLevel*(buf: var seq[uint8],
    plev: uint16): ImageResult[bool] =
  ## Write Plev (PIH body +6) and verify via `jxsCheckLevel`.
  let bR = jxsPihBodyOffset(buf)
  if not bR.ok: return err[bool](bR.err)
  let at = bR.value + 6
  let bytes = @[uint8(plev shr 8), uint8(plev and 0xFF)]
  let save = buf.toSeq()
  for i in 0..<2: buf[at+i] = bytes[i]
  let hR = parseJxsCodestream(buf)
  if not hR.ok:
    buf = save
    return err[bool](hR.err)
  let gR = jxsCheckLevel(hR.value, buf.len)
  if not gR.ok:
    buf = save
    return err[bool](gR.err)
  ok(true)

proc jxsDeclareCbr*(buf: var seq[uint8]): ImageResult[bool] =
  ## Write the SOC..EOC byte count into Lcod (constant-bitrate
  ## self-description, Table 11). Requires an EOC-terminated buffer.
  if buf.len < 4 or buf[buf.len-2] != 0xFF or buf[buf.len-1] != 0x11:
    return err[bool](decodingError("jxs: declare_cbr needs EOC end"))
  let bR = jxsPihBodyOffset(buf)
  if not bR.ok: return err[bool](bR.err)
  let n = buf.len
  if n > int(high(uint32)):
    return err[bool](decodingError("jxs: codestream exceeds Lcod range"))
  let bytes = @[uint8(n shr 24), uint8((n shr 16) and 0xFF),
    uint8((n shr 8) and 0xFF), uint8(n and 0xFF)]
  let r = jxsPatchAndVerify(buf, bR.value, bytes)
  if not r.ok: return err[bool](r.err)
  # Lcod match is verified against the patched length itself.
  let hR = parseJxsCodestream(buf)
  if not hR.ok: return err[bool](hR.err)
  let gR = jxsCheckLevel(hR.value, buf.len)
  if not gR.ok: return err[bool](gR.err)
  ok(true)

proc jxsDeclareVbr*(buf: var seq[uint8]): ImageResult[bool] =
  ## Withdraw a CBR declaration (Lcod = 0, variable bitrate).
  let bR = jxsPihBodyOffset(buf)
  if not bR.ok: return err[bool](bR.err)
  let r = jxsPatchAndVerify(buf, bR.value, @[0'u8, 0, 0, 0])
  if not r.ok: return err[bool](r.err)
  ok(true)

proc jxsInsertCom*(buf: var seq[uint8], tcom: uint16,
    dcom: openArray[uint8]): ImageResult[bool] =
  ## Insert one COM segment before the first SLH (§A.4.10). Rejected
  ## inside a CBR-declared stream (it would falsify Lcod).
  if dcom.len > 0xFFFF - 4:
    return err[bool](decodingError("jxs: COM payload too large"))
  let bR = jxsPihBodyOffset(buf)
  if not bR.ok: return err[bool](bR.err)
  let lcod = (buf[bR.value].uint32 shl 24) or
    (buf[bR.value+1].uint32 shl 16) or
    (buf[bR.value+2].uint32 shl 8) or buf[bR.value+3].uint32
  if lcod != 0:
    return err[bool](decodingError("jxs: COM insert into CBR stream"))
  let sR = jxsFirstSlhOffset(buf)
  if not sR.ok: return err[bool](sR.err)
  var segm: seq[uint8] = @[0xFF'u8, 0x15,
    uint8(((4 + dcom.len) shr 8) and 0xFF),
    uint8((4 + dcom.len) and 0xFF),
    uint8(tcom shr 8), uint8(tcom and 0xFF)]
  for b in dcom: segm.add(b)
  let at = sR.value
  buf = buf[0..<at] & segm & buf[at..^1]
  ok(true)

proc jxsPadToSize*(buf: var seq[uint8],
    target: int): ImageResult[bool] =
  ## Grow to exactly `target` bytes with vendor-specific COM padding
  ## (Tcom=0x8000, zero Dcom) before the first SLH. Gaps of 1..5 bytes
  ## are unpaddable (smallest COM segment is 6 bytes).
  if target < buf.len:
    return err[bool](decodingError("jxs: cannot pad down"))
  var gap = target - buf.len
  if gap == 0: return ok(true)
  if gap < JxsComMinSeg:
    return err[bool](decodingError("jxs: gap too small for COM pad"))
  let sR = jxsFirstSlhOffset(buf)
  if not sR.ok: return err[bool](sR.err)
  var pad: seq[uint8] = @[]
  while gap > 0:
    var segm: int
    if gap <= JxsComMaxSeg: segm = gap
    elif gap - JxsComMaxSeg >= JxsComMinSeg: segm = JxsComMaxSeg
    else: segm = JxsComMaxSeg - JxsComMinSeg
    pad.add(0xFF'u8); pad.add(0x15'u8)
    pad.add(uint8(((segm - 2) shr 8) and 0xFF))
    pad.add(uint8((segm - 2) and 0xFF))
    pad.add(uint8(JxsTcomVendor shr 8)); pad.add(uint8(JxsTcomVendor and 0xFF))
    for _ in 0..<(segm - JxsComMinSeg): pad.add(0)
    gap -= segm
  let at = sR.value
  buf = buf[0..<at] & pad & buf[at..^1]
  if buf.len != target:
    return err[bool](decodingError("jxs: pad size mismatch"))
  ok(true)

proc jxsDeclareCbrPadded*(buf: var seq[uint8],
    target: int): ImageResult[bool] =
  ## Pad to exactly `target` bytes, then declare Lcod (CBR pair).
  let pR = jxsPadToSize(buf, target)
  if not pR.ok: return err[bool](pR.err)
  jxsDeclareCbr(buf)

func jxsPickLevelHi*(w, h: uint32): uint8 =
  ## Smallest level high byte admitting w×h (rate-tied twins resolve
  ## to the lower member); 0x00 when even 10k-1 is exceeded.
  let s = uint64(w) * uint64(h)
  for (hi, mw, mh, ml) in [(0x10'u8, 2048'u32, 8192'u32, 4194304'u64),
      (0x20'u8, 4096'u32, 16384'u32, 8912896'u64),
      (0x24'u8, 4096'u32, 16384'u32, 16777216'u64),
      (0x30'u8, 8192'u32, 32768'u32, 35651584'u64),
      (0x34'u8, 8192'u32, 32768'u32, 67108864'u64),
      (0x40'u8, 10240'u32, 40960'u32, 104857600'u64)]:
    if w <= mw and h <= mh and s <= ml: return hi
  0x00'u8

func jxsPickSublevelLo*(csLen: int, levelHi: uint8,
    ppih: uint16): uint8 =
  ## Smallest sublevel low byte whose Ssl,max admits csLen (3/6/9/12,
  ## then Full for a non-unrestricted profile); 0x00 when unbounded.
  if levelHi == 0x00: return 0x00'u8
  let lb = jxsLevelBounds(levelHi)
  let lmax = lb.l
  if lmax == 0: return 0x00'u8
  for (lo, nbpp) in [(0x04'u8, 3'u32), (0x08'u8, 6'u32),
      (0x0C'u8, 9'u32), (0x10'u8, 12'u32)]:
    if uint64(csLen) <= lmax * nbpp div 8: return lo
  if ppih != 0: return 0x80'u8
  0x00'u8

proc jxsPickProfile*(buf: openArray[uint8]): ImageResult[uint16] =
  ## First profile (Light → Main → High) whose gates admit the stream;
  ## 0x0000 (Unrestricted) when none does.
  let hR = parseJxsCodestream(buf)
  if not hR.ok: return err[uint16](hR.err)
  for ppih in [0x1500'u16, 0x2500, 0x1A00, 0x3540, 0x3A40, 0x3E40,
      0x4A40, 0x4E40]:
    var h = hR.value
    h.pih.ppih = ppih
    if jxsCheckProfile(h).ok: return ok(ppih)
  ok(0x0000'u16)

proc jxsDeclareAuto*(buf: var seq[uint8],
    cbr: bool): ImageResult[tuple[ppih, plev: uint16]] =
  ## Tightest verified (profile, level+sublevel), plus Lcod when `cbr`.
  let pR = jxsPickProfile(buf)
  if not pR.ok: return err[tuple[ppih, plev: uint16]](pR.err)
  let ppih = pR.value
  if ppih != 0:
    let dR = jxsDeclareProfile(buf, ppih)
    if not dR.ok: return err[tuple[ppih, plev: uint16]](dR.err)
  let hR = parseJxsCodestream(buf)
  if not hR.ok: return err[tuple[ppih, plev: uint16]](hR.err)
  let hi = jxsPickLevelHi(hR.value.pih.wf.uint32,
    hR.value.pih.hf.uint32)
  let lo = jxsPickSublevelLo(buf.len, hi, ppih)
  let plev = (hi.uint16 shl 8) or lo.uint16
  if plev != 0:
    let lR = jxsDeclareLevel(buf, plev)
    if not lR.ok: return err[tuple[ppih, plev: uint16]](lR.err)
  if cbr:
    let cR = jxsDeclareCbr(buf)
    if not cR.ok: return err[tuple[ppih, plev: uint16]](cR.err)
  ok((ppih, plev))

# ---------------------------------------------------------------------------
# CBR rate allocation: pick per-slice Q[p] against a byte budget, then
# emit an exactly-`targetBytes` self-described stream (COM pad + Lcod).
# Mirrors the reference three-pass search (lossless probe, uniform-Q
# bisect, per-slice relaxation by spatial activity). Monotonicity of
# length in Q is empirical, so the bisect is a search, not a model.

proc jxsSliceActivities*(planesU: seq[seq[uint16]], w, h: int,
    sx, sy: seq[uint8], nly: uint8, hslRows, nSlices: int): seq[uint64] =
  ## Per-slice L1 row-gradient activity over the slice's image rows.
  result = newSeq[uint64](nSlices)
  let hpPow = if nly == 0: 1 else: 1 shl nly.int
  for t in 0..<nSlices:
    let y0 = t * hslRows * hpPow
    let y1 = min((t + 1) * hslRows * hpPow, h)
    var act: uint64 = 0
    for i in 0..<planesU.len:
      let sxi = max(sx[i].int, 1)
      let syi = max(sy[i].int, 1)
      let cwI = (w + sxi - 1) div sxi
      let r0 = y0 div syi
      let r1 = min((y1 + syi - 1) div syi,
        (h + syi - 1) div syi)
      for r in r0+1..<r1:
        for x in 0..<cwI:
          let a = planesU[i][r * cwI + x].int
          let b = planesU[i][(r - 1) * cwI + x].int
          act += uint64(abs(a - b))
    result[t] = act

proc jxsPickQBytes*(nSlices: int, targetBytes: int,
    encodeFn: proc(qs: seq[uint8]): ImageResult[seq[uint8]],
    activity: seq[uint64] = @[]): ImageResult[seq[uint8]] =
  ## Q[p] vector with encoded length <= targetBytes (see above).
  if targetBytes <= 0:
    return err[seq[uint8]](decodingError("jxs: target_bytes must be > 0"))
  if nSlices <= 0:
    return err[seq[uint8]](decodingError("jxs: no slices"))
  let qZero = newSeq[uint8](nSlices)
  let csZero = encodeFn(qZero)
  if not csZero.ok: return err[seq[uint8]](csZero.err)
  if csZero.value.len <= targetBytes: return ok(qZero)
  # Uniform-Q bisect over 1..15 (monotonic search, not a model).
  var lo: uint8 = 1
  var hi: uint8 = 15
  var bestQ: uint8 = 0
  var bestLen = high(int)
  var mid = 0'u8
  while lo <= hi:
    mid = (lo + hi) div 2
    var qv = newSeq[uint8](nSlices)
    for t in 0..<nSlices: qv[t] = mid
    let csR = encodeFn(qv)
    if not csR.ok: return err[seq[uint8]](csR.err)
    if csR.value.len <= targetBytes:
      bestQ = mid
      bestLen = csR.value.len
      if mid == 0: break
      if mid == 1: break
      hi = mid - 1
    else:
      if mid == 15: break
      lo = mid + 1
  if bestQ == 0:
    var qv = newSeq[uint8](nSlices)
    for t in 0..<nSlices: qv[t] = 15
    let csR = encodeFn(qv)
    if not csR.ok: return err[seq[uint8]](csR.err)
    return err[seq[uint8]](decodingError("jxs: target unreachable; Q=15 emits " &
      $csR.value.len & " bytes"))
  if nSlices == 1: return ok(@[bestQ])
  # Per-slice relaxation: lowest-activity slices drop one Q step at a
  # time while the candidate still fits; repeat to a fixpoint.
  var order = newSeq[int](nSlices)
  for t in 0..<nSlices: order[t] = t
  if activity.len == nSlices:
    var keyed = newSeq[(uint64, int)](nSlices)
    for t in 0..<nSlices: keyed[t] = (activity[t], t)
    # insertion sort (nSlices is small; no algorithm import needed)
    for a in 1..<nSlices:
      let kv = keyed[a]
      var b = a
      while b > 0 and keyed[b-1][0] > kv[0]:
        keyed[b] = keyed[b-1]
        dec b
      keyed[b] = kv
    for t in 0..<nSlices: order[t] = keyed[t][1]
  var best = newSeq[uint8](nSlices)
  for t in 0..<nSlices: best[t] = bestQ
  while true:
    var changed = false
    for t in order:
      if best[t] == 0: continue
      var trial = best
      dec trial[t]
      let csR = encodeFn(trial)
      if not csR.ok: return err[seq[uint8]](csR.err)
      if csR.value.len <= targetBytes:
        best = trial
        bestLen = csR.value.len
        changed = true
    if not changed: break
  ok(best)

proc jxsEncodeCbr*(w, h: int, planesU: seq[seq[uint16]], bd: uint8,
    cpih: uint8, nlx: uint8 = 1, nly: uint8 = 1,
    targetBytes: int = 0, multiSlice = false,
    sampling: seq[(uint8, uint8)] = @[],
    bwAx: uint8 = 0, fqAx: uint8 = 0,
    nltKind: uint8 = 0, nltDco: int32 = 0,
    nltT1: uint32 = 0, nltT2: uint32 = 0, nltE: uint8 = 0,
    qpih: uint8 = 0, sd: uint8 = 0,
    weights: seq[(uint8, uint8)] = @[],
    stE1: uint8 = 0, stE2: uint8 = 0, stCt: uint8 = 0,
    stCf: uint8 = 0, bitDepths: seq[uint8] = @[],
    annexH: bool = false,
    autoSignal: bool = true): ImageResult[tuple[cs: seq[uint8],
      qSlices: seq[uint8]]] =
  ## Constant-bitrate emission: rate-allocate Q[p] against `targetBytes`,
  ## emit exactly `targetBytes` bytes (COM pad + Lcod), and — when
  ## `autoSignal` — declare the tightest verified profile/level/sublevel.
  if targetBytes <= 0:
    return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](
      decodingError("jxs: target_bytes must be > 0"))
  let hpPow = if nly == 0: 1 else: 1 shl nly.int
  let npY = (h + hpPow - 1) div hpPow
  let hslRows = if multiSlice: 1 else: npY
  if hslRows <= 0:
    return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](
      decodingError("jxs: slice rows resolve to zero"))
  let nSlices = (npY + hslRows - 1) div hslRows
  var sx = newSeq[uint8](planesU.len)
  var sy = newSeq[uint8](planesU.len)
  for i in 0..<sx.len: sx[i] = 1; sy[i] = 1
  if sampling.len > 0:
    for i in 0..<sx.len:
      sx[i] = sampling[i][0]; sy[i] = sampling[i][1]
  let act = jxsSliceActivities(planesU, w, h, sx, sy, nly, hslRows,
    nSlices)
  proc encFn(qs: seq[uint8]): ImageResult[seq[uint8]] =
    jxsEncodeLossless(w, h, planesU, bd, cpih, nlx, nly, 0,
      multiSlice, sampling, bwAx, fqAx, nltKind, nltDco, nltT1,
      nltT2, nltE, qpih, sd, weights, stE1, stE2, stCt, stCf,
      bitDepths, annexH, qs)
  let qR = jxsPickQBytes(nSlices, targetBytes, encFn, act)
  if not qR.ok:
    return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](qR.err)
  var qs = qR.value
  var csR = encFn(qs)
  if not csR.ok:
    return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](csR.err)
  var cs = csR.value
  if targetBytes - cs.len in 1..5:
    # Gap smaller than the smallest COM segment: re-allocate against
    # target-6 to open a paddable gap (reference regime).
    let qR2 = jxsPickQBytes(nSlices, targetBytes - 6, encFn, act)
    if not qR2.ok:
      return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](qR2.err)
    qs = qR2.value
    csR = encFn(qs)
    if not csR.ok:
      return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](csR.err)
    cs = csR.value
  let padR = jxsDeclareCbrPadded(cs, targetBytes)
  if not padR.ok:
    return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](padR.err)
  if autoSignal:
    let aR = jxsDeclareAuto(cs, false) # Lcod already declared; keep it
    if not aR.ok:
      return err[tuple[cs: seq[uint8], qSlices: seq[uint8]]](aR.err)
  ok((cs, qs))

# ---------------------------------------------------------------------------
# Part-3 `.jxs` file writer (21122-3 Annex A, minimal conforming set):
# Signature + FileType + Header(ihdr + CICP colr [+ cdef]) + jp2c.

proc jxsPutBox(outP: var seq[uint8], tbox: uint32, payload: openArray[uint8]) =
  let L = payload.len + 8
  outP.add(uint8(L shr 24))
  outP.add(uint8((L shr 16) and 0xFF))
  outP.add(uint8((L shr 8) and 0xFF))
  outP.add(uint8(L and 0xFF))
  outP.add(uint8(tbox shr 24))
  outP.add(uint8((tbox shr 16) and 0xFF))
  outP.add(uint8((tbox shr 8) and 0xFF))
  outP.add(uint8(tbox and 0xFF))
  for b in payload: outP.add(b)

proc writeJxsFile*(cs: openArray[uint8], matrix = 1'u8,
    fullRange = false, hasAlpha = false): ImageResult[seq[uint8]] =
  ## Wrap a bare codestream in a minimal conforming `.jxs` file.
  ## `matrix`: CICP matrix code point (0 = identity/RGB, 1 = BT.709);
  ## `fullRange` sets the CICP V flag; `hasAlpha` emits a `cdef` box.
  let hR = parseJxsCodestream(@cs)
  if not hR.ok: return err[seq[uint8]](hR.err)
  let h = hR.value
  let bd0 = h.comps[0].bitDepth
  var mixedBd = false
  for c in h.comps:
    if c.bitDepth != bd0: mixedBd = true
  var outP: seq[uint8] = @[]
  for b in JxsSigBox: outP.add(b)
  var ft: seq[uint8] = @[]
  for b in [0x6A'u8, 0x78, 0x73, 0x20]: ft.add(b) # major 'jxs '
  for b in [0'u8, 0, 0, 0]: ft.add(b)             # minor 0
  for b in [0x6A'u8, 0x78, 0x73, 0x20]: ft.add(b) # compat 'jxs '
  jxsPutBox(outP, 0x66747970'u32, ft) # 'ftyp'
  # Image Header: HEIGHT(u32)+WIDTH(u32)+NC(u16)+BPC+C+UnkC+IPR.
  # (Wf/Hf are u16 fields; the high bytes are zero.)
  var ih: seq[uint8] = @[0'u8, 0]
  ih.add(uint8(h.pih.hf shr 8)); ih.add(uint8(h.pih.hf and 0xFF))
  ih.add(@[0'u8, 0])
  ih.add(uint8(h.pih.wf shr 8)); ih.add(uint8(h.pih.wf and 0xFF))
  ih.add(uint8(h.pih.nc.int shr 8)); ih.add(uint8(h.pih.nc and 0xFF))
  if mixedBd: ih.add(0xFF) # BPC: varying depths
  else: ih.add(bd0 - 1) # BPC: unsigned, (bpc & 0x7F)+1 = depth
  ih.add(12)     # C: JPEG XS
  ih.add(0)      # UnkC
  ih.add(0)      # IPR
  var inner: seq[uint8] = @[]
  jxsPutBox(inner, 0x69686472'u32, ih) # 'ihdr'
  # CICP colour: METH=5, PREC=0, APPROX=0, CP=2, TC=2, MC, V.
  var colr = @[5'u8, 0, 0, 0, 2, 0, 2]
  colr.add(uint8(matrix shr 8)); colr.add(uint8(matrix and 0xFF))
  colr.add(if fullRange: 0x80'u8 else: 0x00'u8)
  jxsPutBox(inner, 0x636F6C72'u32, colr) # 'colr'
  if hasAlpha:
    var cdef = @[uint8(h.pih.nc.int shr 8), uint8(h.pih.nc and 0xFF)]
    for i in 0..<h.pih.nc.int - 1:
      cdef.add(uint8(i shr 8)); cdef.add(uint8(i and 0xFF))
      cdef.add(0); cdef.add(0) # Typ=0 colour
      cdef.add(uint8((i+1) shr 8)); cdef.add(uint8((i+1) and 0xFF))
    let a = h.pih.nc.int - 1
    cdef.add(uint8(a shr 8)); cdef.add(uint8(a and 0xFF))
    cdef.add(0); cdef.add(1) # Typ=1 opacity
    cdef.add(0); cdef.add(0) # Assoc=0 whole image
    jxsPutBox(inner, 0x63646566'u32, cdef) # 'cdef'
  jxsPutBox(outP, 0x6A787368'u32, inner) # 'jxsh'
  jxsPutBox(outP, 0x6A703263'u32, cs) # 'jp2c'
  ok(outP)
