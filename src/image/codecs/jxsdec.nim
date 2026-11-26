# JPEG XS decoder — framing + picture header (Phase 0/1).
#
# Pure-Nim port of the ISO/IEC 21122-1:2022 marker chain. Reference
# implementation: oxideav-jpegxs (MIT, (c) 2026 Karpeles Lab Inc.),
# used as the interoperability reference; this file is original Nim
# code under the workspace MIT license (holder "Nimbase Community").
# The SPECTEXT structure (marker values, PIH/CDT layouts, CAP bits,
# header ordering rules) follows ISO/IEC 21122-1 Table A.2/A.7/etc.
#
# Status: framing + `jxsInfo` + picture-level conformance gates work.
# Sample decode (entropy/DWT) is follow-up phases —
# `decodeJxsRaw`/`decodeJxs` return `ekUnsupported` after the headers
# validate.
import ./../error
import ./../dynamic
import ./../buffer
import ./../color
import ./../limits

const
  JxsSoc* = 0xFF10'u16
  JxsEoc* = 0xFF11'u16
  JxsMkrPih* = 0xFF12'u16
  JxsMkrCdt* = 0xFF13'u16
  JxsMkrWgt* = 0xFF14'u16
  JxsMkrCom* = 0xFF15'u16
  JxsMkrNlt* = 0xFF16'u16
  JxsMkrCwd* = 0xFF17'u16
  JxsMkrCts* = 0xFF18'u16
  JxsMkrCrg* = 0xFF19'u16
  JxsMkrSlh* = 0xFF20'u16
  JxsMkrCap* = 0xFF50'u16

  JxsSigBox*: array[12, uint8] = [0x00'u8, 0x00, 0x00, 0x0C, 0x4A, 0x58,
    0x53, 0x20, 0x0D, 0x0A, 0x87, 0x0A]
  JxsCodeStreamBox: uint32 = 0x6A703263'u32 # 'jp2c'

type
  JxsPih* = object
    lcod*: uint32
    ppih*: uint16
    plev*: uint16
    wf*: uint16
    hf*: uint16
    cw*: uint16
    hsl*: uint16
    nc*: uint8
    ng*: uint8
    ss*: uint8
    bw*: uint8
    fq*: uint8
    br*: uint8
    fslc*: uint8
    ppoc*: uint8
    cpih*: uint8
    nlx*: uint8
    nly*: uint8
    lh*: uint8
    rl*: uint8
    qpih*: uint8
    fs*: uint8
    rm*: uint8

  JxsComp* = object
    bitDepth*: uint8
    sx*: uint8
    sy*: uint8

  JxsSlice* = object
    yslh*: uint16
    dataOff*: int
    dataLen*: int

  JxsHeaders* = object
    pih*: JxsPih
    comps*: seq[JxsComp]
    cap*: seq[uint8]
    wgt*: seq[uint8]
    nlt*: seq[uint8]
    hasNlt*: bool
    cwdSd*: int # -1 = absent (Sd=0), else 1..Nc-1
    cts*: seq[uint8]
    hasCts*: bool
    crg*: seq[uint8]
    hasCrg*: bool
    comCount*: int
    slices*: seq[JxsSlice]
    eocFound*: bool
    boxed*: bool
    codestreamLen*: int

  JxsInfo* = object
    width*: uint32
    height*: uint32
    numComps*: int
    bitDepth*: uint8
    cpih*: uint8
    lossless*: bool
    boxed*: bool
    profile*: uint16
    level*: uint16

func u16be(d: openArray[uint8], p: int): uint16 =
  (uint16(d[p]) shl 8) or uint16(d[p+1])

func u32be(d: openArray[uint8], p: int): uint32 =
  (uint32(d[p]) shl 24) or (uint32(d[p+1]) shl 16) or
    (uint32(d[p+2]) shl 8) or uint32(d[p+3])

func isJxsFile*(data: openArray[uint8]): bool =
  if data.len < 12: return false
  for i in 0..<12:
    if data[i] != JxsSigBox[i]: return false
  true

func probeJxs*(data: openArray[uint8]): bool =
  ## Allocation-free sniff: bare codestream (SOC+CAP) or Signature box.
  if data.len >= 4 and data[0] == 0xFF and data[1] == 0x10 and
      data[2] == 0xFF and data[3] == 0x50:
    return true
  isJxsFile(data)

proc parsePih(body: openArray[uint8]): ImageResult[JxsPih] =
  if body.len != 24:
    return err[JxsPih](decodingError("jxs: PIH body must be 24 bytes"))
  var h: JxsPih
  h.lcod = u32be(body, 0)
  h.ppih = u16be(body, 4)
  h.plev = u16be(body, 6)
  h.wf = u16be(body, 8)
  h.hf = u16be(body, 10)
  h.cw = u16be(body, 12)
  h.hsl = u16be(body, 14)
  h.nc = body[16]
  h.ng = body[17]
  h.ss = body[18]
  h.bw = body[19]
  h.fq = body[20] shr 4
  h.br = body[20] and 0x0F
  h.fslc = (body[21] shr 7) and 1
  h.ppoc = (body[21] shr 4) and 7
  h.cpih = body[21] and 0x0F
  h.nlx = body[22] shr 4
  h.nly = body[22] and 0x0F
  h.lh = (body[23] shr 7) and 1
  h.rl = (body[23] shr 6) and 1
  h.qpih = (body[23] shr 4) and 3
  h.fs = (body[23] shr 2) and 3
  h.rm = body[23] and 3
  if h.nc == 0 or h.nc > 8:
    return err[JxsPih](decodingError("jxs: PIH Nc must be 1..=8"))
  if h.wf == 0 or h.hf == 0:
    return err[JxsPih](decodingError("jxs: PIH dimensions must be non-zero"))
  if h.cpih != 0 and h.cpih != 1 and h.cpih != 3:
    return err[JxsPih](decodingError("jxs: PIH Cpih reserved"))
  if h.qpih > 1:
    return err[JxsPih](decodingError("jxs: PIH Qpih reserved"))
  if h.fs > 1:
    return err[JxsPih](decodingError("jxs: PIH Fs reserved"))
  if h.rm > 1:
    return err[JxsPih](decodingError("jxs: PIH Rm reserved"))
  if h.ppoc != 0:
    return err[JxsPih](decodingError("jxs: PIH Ppoc reserved"))
  if h.ng != 4:
    return err[JxsPih](decodingError("jxs: PIH Ng must be 4"))
  if h.ss != 8:
    return err[JxsPih](decodingError("jxs: PIH Ss must be 8"))
  ok(h)

proc parseCdt(body: openArray[uint8], nc: int): ImageResult[seq[JxsComp]] =
  if body.len != 2 * nc:
    return err[seq[JxsComp]](decodingError("jxs: CDT body length mismatch"))
  var cs: seq[JxsComp] = @[]
  for i in 0..<nc:
    let bd = body[i*2]
    let sx = body[i*2+1] shr 4
    let sy = body[i*2+1] and 0x0F
    if bd < 8 or bd > 16:
      return err[seq[JxsComp]](decodingError("jxs: CDT bit depth 8..=16"))
    if sx == 0 or sy == 0:
      return err[seq[JxsComp]](decodingError("jxs: CDT sampling must be >= 1"))
    cs.add(JxsComp(bitDepth: bd, sx: sx, sy: sy))
  ok(cs)

proc checkCap(caps: openArray[uint8]): ImageResult[bool] =
  ## Reject capability bits this decoder does not implement:
  ## known = {1,2,3,4,5,6,8}; unknown = {0,7,>=9}.
  for bit in 0..<(caps.len * 8):
    if bit in [1, 2, 3, 4, 5, 6, 8]: continue
    let by = bit div 8
    let m = uint8(1) shl uint8(7 - (bit mod 8))
    if (caps[by] and m) != 0:
      return err[bool](unsupportedError(ukGenericFeature,
        "jxs: unimplemented CAP bit " & $bit))
  ok(true)

# ---------------------------------------------------------------------------
# Annex B geometry walker (picture → slices → precincts → packets).
# Port of the oxideav-jpegxs `slice_walker` enumeration: band ids are
# `b = (Nc-Sd)*β + i`, packets group all components of one (λ,β) jointly.

type
  JxsBandWeight* = object
    gain*: uint8
    priority*: uint8

  JxsBand* = object
    wpb*: uint32
    gain*: uint8
    priority*: uint8
    l0*: uint16
    l1*: uint16
    exists*: bool

  JxsPacketEntry* = object
    band*: uint16
    line*: uint16

  JxsPrecinctPlan* = object
    p*: uint32
    hp*: uint32
    wp*: uint32
    cs*: uint32
    bands*: seq[JxsBand]
    packets*: seq[seq[JxsPacketEntry]]
    bandComp*: seq[uint8]
    bandBeta*: seq[uint32]
    bandLocalBeta*: seq[uint32]

  JxsSlicePlan* = object
    t*: uint32
    pFirst*: uint32
    nPrecincts*: uint32
    precincts*: seq[JxsPrecinctPlan]

  JxsPicturePlan* = object
    slices*: seq[JxsSlicePlan]
    nlx*: uint8
    nly*: uint8
    nBands*: uint32
    nBeta*: uint32
    wf*: uint32
    hf*: uint32
    nDecomposed*: uint32
    nc*: uint8
    sx*: seq[uint8]
    sy*: seq[uint8]
    npX*: uint32
    npY*: uint32
    cs*: uint32
    sd*: uint8

func divCeil32(a, b: uint32): uint32 =
  if b == 0: 0 else: (a + b - 1) div b

func satSub32(a, b: uint32): uint32 =
  if a < b: 0 else: a - b

func satSub8(a, b: uint8): uint8 =
  if a < b: 0 else: a - b

func jxsNBeta(nlx, nly: uint8): uint32 =
  let mn = min(nlx, nly).uint32
  let mx = max(nlx, nly).uint32
  2 * mn + mx + 1

proc jxsBetaLevels(beta: uint32, nlx, nly: uint8):
    tuple[dx, dy: uint32, tx, ty: bool] =
  ## Annex B.3 inverse enumeration (decoder side: β → levels).
  let nlxU = nlx.uint32
  let nlyU = nly.uint32
  if nlyU == 0:
    if beta == 0: return (nlxU, 0'u32, false, false)
    return (nlxU + 1 - beta, 0'u32, true, false)
  let beta1 = nlxU - nlyU + 1
  if beta < beta1:
    if beta == 0: return (nlxU, nlyU, false, false)
    return (nlxU + 1 - beta, nlyU, true, false)
  let groupIn = beta - beta1
  let triple = groupIn div 3
  let within = groupIn mod 3
  let dy = nlyU - triple
  case within
  of 0: (dy, dy, true, false)
  of 1: (dy, dy, false, true)
  else: (dy, dy, true, true)

proc jxsPicBetaToLocal*(betaPic: uint32, nlx, nlyPic, sy: uint8): int =
  ## Picture-β → chroma-local-β; -1 when bx[β,i] = 0 (no band).
  let log2sy =
    case sy
    of 1: 0'u8
    of 2: 1'u8
    of 4: 2'u8
    else: return -1
  let nlyI = satSub8(nlyPic, log2sy)
  if log2sy == 0: return int(betaPic)
  let (dxPic, dyPic, tx, ty) = jxsBetaLevels(betaPic, nlx, nlyPic)
  let nlyPicU = nlyPic.uint32
  let nlyIU = nlyI.uint32
  let nlxU = nlx.uint32
  let pow: uint32 =
    if dyPic > nlyPicU: 1
    elif nlyPicU - dyPic >= 32: 1
    else: 1'u32 shl (nlyPicU - dyPic)
  let l0img: uint32 = if ty: pow else: 0
  if l0img mod sy.uint32 != 0: return -1
  if not ty and not tx: return 0
  if not ty:
    let beta1c = nlxU - nlyIU + 1
    if dxPic > nlyIU:
      return int(nlxU + 1 - dxPic)
    return int(beta1c + 3 * (nlyIU - dxPic))
  if dyPic > nlyIU: return -1
  let beta1c = nlxU - nlyIU + 1
  let triple = nlyIU - dyPic
  let within: uint32 = if tx: 2 else: 1
  int(beta1c + 3 * triple + within)

proc jxsParseWgt(body: openArray[uint8], nExisting: int):
    ImageResult[seq[JxsBandWeight]] =
  if body.len != nExisting * 2:
    return err[seq[JxsBandWeight]](decodingError(
      "jxs: WGT body must be 2*N_existing"))
  var outP: seq[JxsBandWeight] = @[]
  for i in 0..<nExisting:
    if body[i*2] > 15:
      return err[seq[JxsBandWeight]](decodingError("jxs: WGT gain > 15"))
    outP.add(JxsBandWeight(gain: body[i*2], priority: body[i*2+1]))
  ok(outP)

proc jxsPacketLayouts(nlx, nly: uint8, nc, nDecomposed: uint32,
    bands: seq[JxsBand], dy: seq[uint32], sy: seq[uint8],
    linesThisPrecinct: uint32): seq[seq[JxsPacketEntry]] =
  ## Annex B.7 Table B.4: first packet (β1 bands × comps on λ=0),
  ## proxy levels (one joint packet per (λ,β)), Sd tail (one per line).
  var layouts: seq[seq[JxsPacketEntry]] = @[]
  let nlxU = nlx.uint32
  let nlyU = nly.uint32
  let beta1 = max(nlxU, nlyU) - min(nlxU, nlyU) + 1
  var first: seq[JxsPacketEntry] = @[]
  for beta in 0..<beta1:
    for i in 0..<nDecomposed:
      let b = nDecomposed * beta + i
      if b < bands.len.uint32 and bands[b].exists:
        let syI = sy[i].uint32
        let l0b = bands[b].l0.uint32
        if syI != 0 and (l0b * max(syI, 1)) mod syI != 0: continue
        first.add(JxsPacketEntry(band: b.uint16, line: l0b.uint16))
  if first.len > 0: layouts.add(first)
  var nBetaU: uint32 = 0
  if nDecomposed > 0:
    let sdU = nc - nDecomposed
    nBetaU = (bands.len.uint32 - sdU) div nDecomposed
  var beta0 = beta1
  while beta0 < nBetaU:
    if beta0.int >= dy.len: break
    let dyB0 = dy[beta0.int]
    let pow: uint32 =
      if dyB0 > nlyU or nlyU == 0: 1
      else: 1'u32 shl (nlyU - dyB0)
    for lambdaWithin in 0..<pow:
      for beta in beta0..<min(beta0 + 3, nBetaU):
        var pkt: seq[JxsPacketEntry] = @[]
        for i in 0..<nDecomposed:
          let b = nDecomposed * beta + i
          if b >= bands.len.uint32 or not bands[b].exists: continue
          let syI = max(sy[i].uint32, 1)
          let l0b = bands[b].l0.uint32
          let l1b = bands[b].l1.uint32
          let l0img = l0b * syI
          let l1img = l1b * syI
          let lineImg = l0img + lambdaWithin
          if lineImg >= l1img: continue
          if lineImg mod sy[i].uint32 != 0: continue
          pkt.add(JxsPacketEntry(band: b.uint16,
            line: uint16(lineImg div syI)))
        if pkt.len > 0: layouts.add(pkt)
    beta0 += 3
  let sdU = nc - nDecomposed
  if sdU > 0:
    let base = nDecomposed * nBetaU
    for lambda in 0..<linesThisPrecinct:
      for i in 0..<sdU:
        let b = base + i
        if b >= bands.len.uint32 or not bands[b].exists: continue
        if lambda >= bands[b].l1.uint32: continue
        layouts.add(@[JxsPacketEntry(band: b.uint16, line: lambda.uint16)])
  layouts

proc jxsBuildPrecinctPlan(p: uint32, py: uint32, nlx, nly: uint8,
    nBeta, nc, nDecomposed: uint32, sx, sy: seq[uint8],
    nlyPerComp: seq[uint8], cs, hp, npX: uint32, wf, hf: uint32,
    dx, dy: seq[uint32], txA, tyA: seq[bool], existsA: seq[bool],
    localBeta: seq[uint32], hb: seq[uint32],
    weightsByBand: seq[JxsBandWeight], pih: JxsPih):
    ImageResult[JxsPrecinctPlan] =
  let wp: uint32 =
    if (p mod npX) < npX - 1: cs
    else: ((wf - 1) mod cs) + 1
  if wp == 0:
    return err[JxsPrecinctPlan](decodingError("jxs: Wp[p] is zero"))
  let sdU = nc - nDecomposed
  var bands: seq[JxsBand] = @[]
  var bandComp: seq[uint8] = @[]
  var bandBeta: seq[uint32] = @[]
  var bandLocal: seq[uint32] = @[]
  for beta in 0..<nBeta:
    for i in 0..<nDecomposed.int:
      let aIdx = i * nBeta.int + beta.int
      let dxB = dx[aIdx]
      let dyB = dy[aIdx]
      let txB = txA[aIdx]
      let tyU: uint32 = if tyA[aIdx]: 1 else: 0
      let ex = existsA[aIdx]
      var wpb: uint32 = 0
      if ex:
        let wcP = max(divCeil32(wp, sx[i].uint32), 1)
        if not txB:
          wpb = if dxB == 0: wcP else: (wcP + (1'u32 shl dxB) - 1) shr dxB
        else:
          let dm1: uint32 = if dxB == 0: 1 else: 1'u32 shl (dxB - 1)
          wpb = divCeil32(wcP, dm1) div 2
      let nlyI = nlyPerComp[i].uint32
      let dyEff: uint32 = if nly == 0: 0 else: dyB
      let pw: uint32 =
        if dyEff > nlyI or nlyI == 0: 1
        else: 1'u32 shl (nlyI - dyEff)
      let l0 = pw * tyU
      let rowOff = py * pw
      let remain = satSub32(hb[aIdx], rowOff)
      let l1 = l0 + min(remain, pw)
      let w =
        if ex: weightsByBand[(nDecomposed * beta + i.uint32).int]
        else: JxsBandWeight(gain: 0, priority: 0)
      bands.add(JxsBand(wpb: wpb, gain: w.gain, priority: w.priority,
        l0: l0.uint16, l1: l1.uint16, exists: ex))
      bandComp.add(i.uint8)
      bandBeta.add(beta)
      bandLocal.add(localBeta[aIdx])
  let hpRows: uint32 = if nly == 0: 1 else: 1'u32 shl nly
  let rowOffPic = py * hpRows
  let linesPrec = min(hpRows, satSub32(hf, rowOffPic))
  for i in 0..<sdU.int:
    let bTail = (nDecomposed * nBeta + i.uint32).int
    bands.add(JxsBand(wpb: wp, gain: weightsByBand[bTail].gain,
      priority: weightsByBand[bTail].priority, l0: 0,
      l1: linesPrec.uint16, exists: linesPrec > 0))
    bandComp.add((nDecomposed + i.uint32).uint8)
    bandBeta.add(0)
    bandLocal.add(0)
  let packets = jxsPacketLayouts(nlx, nly, nc, nDecomposed, bands, dy, sy,
    linesPrec)
  ok(JxsPrecinctPlan(p: p, hp: hp, wp: wp, cs: cs, bands: bands,
    packets: packets, bandComp: bandComp, bandBeta: bandBeta,
    bandLocalBeta: bandLocal))

proc jxsBuildPlan*(pih: JxsPih, comps: seq[JxsComp], wgt: openArray[uint8],
    sd: uint8): ImageResult[JxsPicturePlan] =
  ## Full Annex B plan. Mirrors `build_plan_sd` validation + enumeration.
  if comps.len != pih.nc.int:
    return err[JxsPicturePlan](decodingError("jxs: CDT/Nc mismatch"))
  let nlx = pih.nlx
  let nly = pih.nly
  if nlx == 0:
    return err[JxsPicturePlan](decodingError("jxs: NL,x must be >= 1"))
  if nly > nlx:
    return err[JxsPicturePlan](unsupportedError(ukGenericFeature,
      "jxs: NL,y > NL,x"))
  let wf = pih.wf.uint32
  let hf = pih.hf.uint32
  if wf == 0 or hf == 0:
    return err[JxsPicturePlan](decodingError("jxs: bad dimensions"))
  let nBeta = jxsNBeta(nlx, nly)
  let nc = pih.nc.uint32
  let sdU = sd.uint32
  let nDecomposed = nc.satSub32(sdU)
  let nBands = nDecomposed * nBeta + sdU
  var sx: seq[uint8] = @[]
  var sy: seq[uint8] = @[]
  for c in comps:
    sx.add(c.sx)
    sy.add(c.sy)
  var nlyPerComp: seq[uint8] = @[]
  for s in sy:
    let lg =
      case s
      of 1: 0'u8
      of 2: 1'u8
      of 4: 2'u8
      else: 0'u8
    nlyPerComp.add(satSub8(nly, lg))
  let arrSize = (nBeta * nc).int
  var wb = newSeq[uint32](arrSize)
  var hb = newSeq[uint32](arrSize)
  var dxA = newSeq[uint32](arrSize)
  var dyA = newSeq[uint32](arrSize)
  var txA = newSeq[bool](arrSize)
  var tyA = newSeq[bool](arrSize)
  var exA = newSeq[bool](arrSize)
  var lbA = newSeq[uint32](arrSize)
  for i, comp in comps:
    if i.uint32 >= nDecomposed: continue
    let wc = divCeil32(wf, comp.sx.uint32)
    let hc = divCeil32(hf, comp.sy.uint32)
    let nlyI = nlyPerComp[i]
    for betaPic in 0..<nBeta.int:
      let idx = i * nBeta.int + betaPic
      let loc = jxsPicBetaToLocal(betaPic.uint32, nlx, nly, comp.sy)
      if loc < 0:
        exA[idx] = false
        lbA[idx] = high(uint32)
        continue
      let (dx, dy, tx, ty) = jxsBetaLevels(loc.uint32, nlx, nlyI)
      dxA[idx] = dx
      dyA[idx] = dy
      txA[idx] = tx
      tyA[idx] = ty
      lbA[idx] = loc.uint32
      let wbb: uint32 =
        if not tx:
          if dx == 0: wc else: (wc + (1'u32 shl dx) - 1) shr dx
        else:
          let dm1: uint32 = if dx == 0: 1 else: 1'u32 shl (dx - 1)
          divCeil32(wc, dm1) div 2
      let hbb: uint32 =
        if not ty:
          if dy == 0: hc else: (hc + (1'u32 shl dy) - 1) shr dy
        else:
          let dm1: uint32 = if dy == 0: 1 else: 1'u32 shl (dy - 1)
          divCeil32(hc, dm1) div 2
      wb[idx] = wbb
      hb[idx] = hbb
      exA[idx] = true
  var maxSx: uint8 = 1
  for s in sx:
    if s > maxSx: maxSx = s
  let cs: uint32 =
    if pih.cw == 0: wf
    else: 8'u32 * pih.cw.uint32 * maxSx.uint32 * (1'u32 shl nlx)
  if cs == 0:
    return err[JxsPicturePlan](decodingError("jxs: Cs is zero"))
  let npX = divCeil32(wf, cs)
  let hpPow: uint32 = if nly == 0: 1 else: 1'u32 shl nly
  let npY = divCeil32(hf, hpPow)
  var nExistW = 0
  for e in exA:
    if e: inc nExistW
  let wgtR = jxsParseWgt(wgt, nExistW + sdU.int)
  if not wgtR.ok: return err[JxsPicturePlan](wgtR.err)
  var weightsByBand = newSeq[JxsBandWeight](nBands.int)
  var cur = 0
  for beta in 0..<nBeta:
    for i in 0..<nDecomposed.int:
      if not exA[i * nBeta.int + beta.int]: continue
      weightsByBand[(nDecomposed * beta + i.uint32).int] = wgtR.value[cur]
      inc cur
  for i in 0..<sdU.int:
    weightsByBand[(nDecomposed * nBeta + i.uint32).int] = wgtR.value[cur]
    inc cur
  var precincts: seq[JxsPrecinctPlan] = @[]
  for py in 0..<npY:
    for px in 0..<npX:
      let p = py * npX + px
      let r = jxsBuildPrecinctPlan(p, py, nlx, nly, nBeta, nc,
        nDecomposed, sx, sy, nlyPerComp, cs, hpPow, npX, wf, hf,
        dxA, dyA, txA, tyA, exA, lbA, hb, weightsByBand, pih)
      if not r.ok: return err[JxsPicturePlan](r.err)
      precincts.add(r.value)
  if pih.hsl == 0:
    return err[JxsPicturePlan](decodingError("jxs: Hsl must be >= 1"))
  var slices: seq[JxsSlicePlan] = @[]
  var pCur: uint32 = 0
  var t: uint32 = 0
  while pCur < precincts.len.uint32:
    let rowsInSlice =
      if (t + 1) * pih.hsl.uint32 > npY: npY - t * pih.hsl.uint32
      else: pih.hsl.uint32
    let npT = npX * rowsInSlice
    if pCur + npT > precincts.len.uint32:
      return err[JxsPicturePlan](decodingError("jxs: slice past precincts"))
    slices.add(JxsSlicePlan(t: t, pFirst: pCur, nPrecincts: npT,
      precincts: precincts[pCur.int..<(pCur + npT).int]))
    pCur += npT
    inc t
  ok(JxsPicturePlan(slices: slices, nlx: nlx, nly: nly, nBands: nBands,
    nBeta: nBeta, wf: wf, hf: hf, nDecomposed: nDecomposed, nc: pih.nc,
    sx: sx, sy: sy, npX: npX, npY: npY, cs: cs, sd: sd))

# ---------------------------------------------------------------------------
# Annex C.2/C.3 packet framing: precinct + packet headers (entropy phase).
# Bit-exact MSB-first layouts per Tables C.1/C.3; sample sub-packets follow.

type
  JxsBitReader* = object
    buf*: seq[uint8]
    bitPos*: int

  JxsPrecinctHdr* = object
    lprc*: uint32
    q*: uint8
    r*: uint8
    d*: seq[uint8] # per band (0 for absent)
    headerBytes*: int

  JxsPacketHdr* = object
    dr*: uint8
    ldat*: uint32
    lcnt*: uint32
    lsgn*: uint32
    shortForm*: bool
    headerBytes*: int

func jxsBrBits(r: JxsBitReader): int = r.buf.len * 8 - r.bitPos

proc jxsBrRead(r: var JxsBitReader, n: int): ImageResult[uint32] =
  if n < 0 or n > 24:
    return err[uint32](decodingError("jxs: bit read width"))
  if r.bitPos + n > r.buf.len * 8:
    return err[uint32](decodingError("jxs: precinct header truncated"))
  var v: uint32 = 0
  for k in 0..<n:
    let p = r.bitPos + k
    let bit = (r.buf[p div 8] shr uint8(7 - (p mod 8))) and 1
    v = (v shl 1) or bit.uint32
  r.bitPos += n
  ok(v)

proc jxsParsePrecinctHdr*(data: openArray[uint8], prec: JxsPrecinctPlan):
    ImageResult[JxsPrecinctHdr] =
  ## Table C.1: Lprc u24, Q u8 (≤31), R u8 (≤NL-1), D u2 per existing
  ## band, then byte alignment.
  var r = JxsBitReader(buf: @data, bitPos: 0)
  let lprcR = jxsBrRead(r, 24)
  if not lprcR.ok: return err[JxsPrecinctHdr](lprcR.err)
  if lprcR.value == 0 or lprcR.value > (1'u32 shl 20) - 1:
    return err[JxsPrecinctHdr](decodingError("jxs: Lprc out of range"))
  let qR = jxsBrRead(r, 8)
  if not qR.ok: return err[JxsPrecinctHdr](qR.err)
  if qR.value > 31:
    return err[JxsPrecinctHdr](decodingError("jxs: Q[p] > 31"))
  let rrR = jxsBrRead(r, 8)
  if not rrR.ok: return err[JxsPrecinctHdr](rrR.err)
  if prec.bands.len > 0 and rrR.value > uint32(prec.bands.len - 1):
    return err[JxsPrecinctHdr](decodingError("jxs: R[p] > NL-1"))
  var d: seq[uint8] = @[]
  for bd in prec.bands:
    if bd.exists:
      let dR = jxsBrRead(r, 2)
      if not dR.ok: return err[JxsPrecinctHdr](dR.err)
      d.add(dR.value.uint8)
    else:
      d.add(0)
  let pad = (8 - (r.bitPos mod 8)) mod 8
  if pad > 0:
    let pR = jxsBrRead(r, pad)
    if not pR.ok: return err[JxsPrecinctHdr](pR.err)
  ok(JxsPrecinctHdr(lprc: lprcR.value, q: qR.value.uint8,
    r: rrR.value.uint8, d: d, headerBytes: r.bitPos div 8))

func jxsUseShortHeader*(pih: JxsPih): bool =
  pih.wf.uint32 * pih.nc.uint32 < 32752 and pih.lh == 0

proc jxsParsePacketHdr*(data: openArray[uint8], shortForm: bool):
    ImageResult[JxsPacketHdr] =
  ## Table C.3: short Dr+15+13+11 (5B) vs long Dr+20+20+15 (7B).
  var r = JxsBitReader(buf: @data, bitPos: 0)
  let drR = jxsBrRead(r, 1)
  if not drR.ok: return err[JxsPacketHdr](drR.err)
  let (ldW, lcW, lsW) =
    if shortForm: (15, 13, 11) else: (20, 20, 15)
  let ldatR = jxsBrRead(r, ldW)
  if not ldatR.ok: return err[JxsPacketHdr](ldatR.err)
  let lcntR = jxsBrRead(r, lcW)
  if not lcntR.ok: return err[JxsPacketHdr](lcntR.err)
  let lsgnR = jxsBrRead(r, lsW)
  if not lsgnR.ok: return err[JxsPacketHdr](lsgnR.err)
  if r.bitPos mod 8 != 0:
    return err[JxsPacketHdr](decodingError("jxs: packet header unaligned"))
  ok(JxsPacketHdr(dr: drR.value.uint8, ldat: ldatR.value,
    lcnt: lcntR.value, lsgn: lsgnR.value, shortForm: shortForm,
    headerBytes: r.bitPos div 8))

func jxsTruncT*(q, g, pr, r: uint8): uint8 =
  ## Annex C.6.2 Table C.10: T[p,b] = clamp(Q-G-(P<R ? 1 : 0), 0, 15).
  let extra: uint8 = if pr < r: 1 else: 0
  let qq = q.int
  let v = qq - g.int - extra.int
  if v <= 0: 0 elif v >= 15: 15 else: v.uint8

proc findCodestream(data: openArray[uint8]): tuple[off, ln: int, boxed: bool] =
  ## For a `.jxs` file, locate the first `jp2c` box payload.
  ## Returns (off, len, true), or (-1, 0, true) when absent.
  var p = 0
  # skip Signature (12) + FileType (second box) generically: walk boxes.
  while p + 8 <= data.len:
    let lb = int(u32be(data, p))
    let tb = u32be(data, p+4)
    var hdr = 8
    var plen = lb - 8
    if lb == 1:
      if p + 16 > data.len: break
      hdr = 16
      # XLBox: 64-bit length; only support values fitting int.
      var hi = u32be(data, p+8)
      var lo = u32be(data, p+12)
      if hi != 0 or lo < uint32(16): break
      plen = int(lo) - 16
    elif lb == 0:
      plen = data.len - (p + 8)
    elif lb < 8:
      break
    if tb == JxsCodeStreamBox:
      return (p + hdr, plen, true)
    if lb == 0: break
    p += hdr + plen
  (-1, 0, true)

proc parseJxsCodestream*(cs: openArray[uint8]): ImageResult[JxsHeaders] =
  ## Marker-chain parse: SOC CAP PIH header-loop SLH* EOC.
  ## Slice lengths use the scan fallback (empty-entropy safe); the
  ## plan-driven Lprc walk lands with the entropy phase.
  let buf = @cs
  var pos = 0
  var h: JxsHeaders
  h.cwdSd = -1
  template need(n: int): bool = pos + (n) <= buf.len
  template rdM(): uint16 =
    if not need(2):
      return err[JxsHeaders](decodingError("jxs: truncated marker"))
    let mm = (uint16(buf[pos]) shl 8) or uint16(buf[pos+1])
    pos += 2
    mm
  template rdS(): seq[uint8] =
    if not need(2):
      return err[JxsHeaders](decodingError("jxs: truncated length"))
    let ll = int(u16be(buf, pos))
    pos += 2
    if ll < 2:
      return err[JxsHeaders](decodingError("jxs: bad segment length"))
    if not need(ll - 2):
      return err[JxsHeaders](decodingError("jxs: truncated segment"))
    var bb = newSeq[uint8](ll - 2)
    for ii in 0..<(ll-2): bb[ii] = buf[pos+ii]
    pos += ll - 2
    bb
  let m0 = rdM()
  if m0 != JxsSoc:
    return err[JxsHeaders](decodingError("jxs: expected SOC"))
  let m1 = rdM()
  if m1 != JxsMkrCap:
    return err[JxsHeaders](decodingError("jxs: expected CAP after SOC"))
  h.cap = rdS()
  let cc = checkCap(h.cap)
  if not cc.ok: return err[JxsHeaders](cc.err)
  let m2 = rdM()
  if m2 != JxsMkrPih:
    return err[JxsHeaders](decodingError("jxs: expected PIH after CAP"))
  let pihB = rdS()
  if pihB.len + 2 != 26:
    return err[JxsHeaders](decodingError("jxs: Lpih must be 26"))
  let ph = parsePih(pihB)
  if not ph.ok: return err[JxsHeaders](ph.err)
  h.pih = ph.value
  let nc = int(h.pih.nc)
  var haveCdt = false
  var haveWgt = false
  var seenSlh = false
  while true:
    if not need(2):
      return err[JxsHeaders](decodingError("jxs: truncated header chain"))
    let m = rdM()
    case m
    of JxsMkrCdt:
      if haveCdt:
        return err[JxsHeaders](decodingError("jxs: duplicate CDT"))
      let b = rdS()
      let c = parseCdt(b, nc)
      if not c.ok: return err[JxsHeaders](c.err)
      h.comps = c.value
      haveCdt = true
    of JxsMkrWgt:
      if haveWgt:
        return err[JxsHeaders](decodingError("jxs: duplicate WGT"))
      h.wgt = rdS()
      haveWgt = true
    of JxsMkrCom:
      discard rdS()
      inc h.comCount
    of JxsMkrNlt:
      if h.hasNlt:
        return err[JxsHeaders](decodingError("jxs: duplicate NLT"))
      h.nlt = rdS()
      h.hasNlt = true
    of JxsMkrCwd:
      if h.cwdSd != -1:
        return err[JxsHeaders](decodingError("jxs: duplicate CWD"))
      let b = rdS()
      if b.len != 1:
        return err[JxsHeaders](decodingError("jxs: CWD body must be 1 byte"))
      let sd = int(b[0])
      if nc <= 3:
        return err[JxsHeaders](decodingError("jxs: CWD needs Nc > 3"))
      if sd == 0 or sd >= nc:
        return err[JxsHeaders](decodingError("jxs: CWD Sd must be 1..Nc-1"))
      h.cwdSd = sd
    of JxsMkrCts:
      if h.hasCts:
        return err[JxsHeaders](decodingError("jxs: duplicate CTS"))
      h.cts = rdS()
      h.hasCts = true
    of JxsMkrCrg:
      if h.hasCrg:
        return err[JxsHeaders](decodingError("jxs: duplicate CRG"))
      h.crg = rdS()
      h.hasCrg = true
    of JxsMkrSlh:
      let b = rdS()
      if b.len != 2:
        return err[JxsHeaders](decodingError("jxs: Lslh must be 4"))
      pos -= (2 + 2 + 2)
      seenSlh = true
      break
    of JxsEoc:
      return err[JxsHeaders](decodingError("jxs: EOC before any slice"))
    else:
      return err[JxsHeaders](decodingError("jxs: unexpected marker in header"))
  if not seenSlh:
    return err[JxsHeaders](decodingError("jxs: missing slice"))
  if not haveCdt:
    return err[JxsHeaders](decodingError("jxs: missing CDT"))
  if not haveWgt:
    return err[JxsHeaders](decodingError("jxs: missing WGT"))
  if h.pih.cpih == 3 and not h.hasCts:
    return err[JxsHeaders](decodingError("jxs: Cpih=3 requires CTS"))
  if h.pih.cpih != 3 and h.hasCts:
    return err[JxsHeaders](decodingError("jxs: CTS without Cpih=3"))
  # Picture-level conformance (Tables A.7/A.8/A.11 + Table 11 floors).
  if h.pih.nlx == 0 or h.pih.nlx > 8:
    return err[JxsHeaders](decodingError("jxs: NL,x must be 1..=8"))
  if h.pih.nly > h.pih.nlx:
    return err[JxsHeaders](unsupportedError(ukGenericFeature,
      "jxs: NL,y > NL,x"))
  if h.pih.hsl == 0:
    return err[JxsHeaders](decodingError("jxs: Hsl must be >= 1"))
  let b0 = h.comps[0].bitDepth
  let bwFqOk = (h.pih.fq == 0 and h.pih.bw == b0) or
    (h.pih.bw == 18 and h.pih.fq == 6) or
    (h.pih.bw == 20 and h.pih.fq == 8)
  if not bwFqOk:
    return err[JxsHeaders](unsupportedError(ukGenericFeature,
      "jxs: (Bw,Fq) outside Table A.8"))
  if h.pih.fq == 0 and h.hasNlt:
    return err[JxsHeaders](decodingError("jxs: NLT with Fq=0 forbidden"))
  if h.pih.fq == 0:
    for i, c in h.comps:
      if c.bitDepth != b0:
        return err[JxsHeaders](decodingError(
          "jxs: Fq=0 requires uniform B[i]"))
  if h.pih.bw == 18 and h.pih.fq == 6:
    if not h.hasNlt:
      return err[JxsHeaders](decodingError("jxs: (18,6) needs NLT"))
    var cap23 = false
    for bit in [2, 3]:
      let by = bit div 8
      let m = uint8(1) shl uint8(7 - (bit mod 8))
      if by < h.cap.len and (h.cap[by] and m) != 0: cap23 = true
    if not cap23:
      return err[JxsHeaders](decodingError("jxs: (18,6) needs CAP bit 2/3"))
  if h.pih.cpih == 1:
    if h.comps.len < 3:
      return err[JxsHeaders](unsupportedError(ukGenericFeature,
        "jxs: RCT needs Nc >= 3"))
    for i in 0..<3:
      if h.comps[i].sx != 1 or h.comps[i].sy != 1:
        return err[JxsHeaders](unsupportedError(ukGenericFeature,
          "jxs: RCT with subsampled component"))
  if h.pih.cpih == 3 and h.comps.len < 4:
    return err[JxsHeaders](decodingError("jxs: Star-Tetrix needs Nc >= 4"))
  # Table 11 dimension floors.
  var maxSx: uint32 = 1
  var maxSy: uint32 = 1
  for c in h.comps:
    if uint32(c.sx) > maxSx: maxSx = uint32(c.sx)
    if uint32(c.sy) > maxSy: maxSy = uint32(c.sy)
  if uint32(h.pih.wf) < maxSx * (1'u32 shl h.pih.nlx) or
      uint32(h.pih.hf) < maxSy * (1'u32 shl h.pih.nly):
    return err[JxsHeaders](decodingError("jxs: picture below Table 11 floor"))
  if h.pih.cw > 0:
    let csW = 8'u64 * uint64(h.pih.cw) * uint64(maxSx) *
      (1'u64 shl h.pih.nlx)
    if csW > 0 and csW < uint64(high(uint32)):
      let cs = uint32(csW)
      let rem = uint32(h.pih.wf) mod cs
      if rem > 0 and rem < maxSx * (1'u32 shl h.pih.nlx):
        return err[JxsHeaders](decodingError("jxs: Cw sliver column"))
  # WGT body sanity (full per-band count check lands with geometry).
  if h.wgt.len mod 2 != 0:
    return err[JxsHeaders](decodingError("jxs: WGT body must be even"))
  for i in countup(0, h.wgt.len - 1, 2):
    if h.wgt[i] > 15:
      return err[JxsHeaders](decodingError("jxs: WGT gain > 15"))
  # Slice walk: plan-driven Lprc lengths when the Annex B plan builds
  # (exact: entropy can't be scanned, JPEG XS has no byte-stuffing);
  # scan fallback only when the plan fails (empty-entropy fixtures).
  let sdPlan: uint8 = if h.cwdSd < 0: 0 else: h.cwdSd.uint8
  let planR = jxsBuildPlan(h.pih, h.comps, h.wgt, sdPlan)
  var plan: JxsPicturePlan
  var havePlan = false
  if planR.ok:
    plan = planR.value
    havePlan = true
  while true:
    let m = rdM()
    if m == JxsEoc:
      h.eocFound = true
      break
    if m != JxsMkrSlh:
      return err[JxsHeaders](decodingError("jxs: expected SLH or EOC"))
    let b = rdS()
    if b.len != 2:
      return err[JxsHeaders](decodingError("jxs: Lslh must be 4"))
    let yslh = u16be(b, 0)
    let dOff = pos
    var dLen = 0
    if havePlan:
      let sIdx = h.slices.len
      if sIdx >= plan.slices.len:
        return err[JxsHeaders](decodingError(
          "jxs: more slices than the plan expects"))
      let sp = plan.slices[sIdx]
      # empty-entropy slice: next two bytes are already a marker.
      let emptySlice = dOff + 1 < buf.len and buf[dOff] == 0xFF and
        (buf[dOff+1] == 0x11 or buf[dOff+1] == 0x20)
      if not emptySlice:
        for prec in sp.precincts:
          var nExist = 0
          for bd in prec.bands:
            if bd.exists: inc nExist
          let hdrBytes = (24 + 8 + 8 + 2 * nExist + 7) div 8
          let pStart = dOff + dLen
          if pStart + 3 > buf.len:
            return err[JxsHeaders](decodingError(
              "jxs: precinct header truncated"))
          let lprc = (buf[pStart].uint32 shl 16) or
            (buf[pStart+1].uint32 shl 8) or buf[pStart+2].uint32
          dLen += hdrBytes + lprc.int
      if dOff + dLen > buf.len:
        return err[JxsHeaders](decodingError("jxs: slice data exceeds end"))
    else:
      var nxt = -1
      var i = dOff
      while i + 1 < buf.len:
        if buf[i] == 0xFF and (buf[i+1] == 0x20 or buf[i+1] == 0x11):
          nxt = i
          break
        inc i
      dLen = if nxt < 0: buf.len - dOff else: nxt - dOff
    h.slices.add(JxsSlice(yslh: yslh, dataOff: dOff, dataLen: dLen))
    pos = dOff + dLen
  h.codestreamLen = buf.len
  ok(h)

proc headersInfo(h: JxsHeaders, boxed: bool): JxsInfo =
  var mx: uint8 = 0
  for c in h.comps:
    if c.bitDepth > mx: mx = c.bitDepth
  JxsInfo(width: uint32(h.pih.wf), height: uint32(h.pih.hf),
    numComps: h.comps.len, bitDepth: mx, cpih: h.pih.cpih,
    lossless: h.pih.fq == 0, boxed: boxed, profile: h.pih.ppih,
    level: h.pih.plev)

proc jxsInfo*(data: openArray[uint8]): ImageResult[JxsInfo] =
  ## Header-only summary. Accepts a bare codestream or a `.jxs` file.
  if isJxsFile(data):
    let (off, ln, _) = findCodestream(data)
    if off < 0:
      return err[JxsInfo](decodingError("jxs: file has no codestream"))
    let h = parseJxsCodestream(data.toOpenArray(off, off + ln - 1))
    if not h.ok: return err[JxsInfo](h.err)
    return ok(headersInfo(h.value, true))
  let h = parseJxsCodestream(data)
  if not h.ok: return err[JxsInfo](h.err)
  ok(headersInfo(h.value, false))

proc decodeJxsRaw*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## Bare-codestream decode. Phase 0/1: framing only.
  let h = parseJxsCodestream(data)
  if not h.ok: return err[DynamicImage](h.err)
  err[DynamicImage](unsupportedError(ukGenericFeature,
    "jxs: sample decode not yet implemented (framing ok: " &
      $h.value.pih.wf & "x" & $h.value.pih.hf & " Nc=" &
      $h.value.pih.nc & ")"))

proc decodeJxs*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## Bare codestream or `.jxs` file decode. Phase 0/1: framing only.
  if isJxsFile(data):
    let (off, ln, _) = findCodestream(data)
    if off < 0:
      return err[DynamicImage](decodingError("jxs: file has no codestream"))
    return decodeJxsRaw(data.toOpenArray(off, off + ln - 1))
  decodeJxsRaw(data)
