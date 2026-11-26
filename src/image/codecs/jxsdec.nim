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
import std/options
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
    nltKind*: uint8 # 0 = none, 1 = quadratic, 2 = extended
    nltDco*: int
    nltT1*: uint32
    nltT2*: uint32
    nltE*: uint8
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

func divCeil32*(a, b: uint32): uint32 =
  if b == 0: 0 else: (a + b - 1) div b

func satSub32*(a, b: uint32): uint32 =
  if a < b: 0 else: a - b

func satSub8*(a, b: uint8): uint8 =
  if a < b: 0 else: a - b

func jxsFDiv2*(a: int): int =
  ## floor(a / 2), backend-independent.
  if a >= 0: a div 2 else: -((-a + 1) div 2)

func jxsFDiv4*(a: int): int =
  ## floor(a / 4), backend-independent.
  if a >= 0: a div 4 else: -((-a + 3) div 4)

func jxsNBeta*(nlx, nly: uint8): uint32 =
  let mn = min(nlx, nly).uint32
  let mx = max(nlx, nly).uint32
  2 * mn + mx + 1

proc jxsBetaLevels*(beta: uint32, nlx, nly: uint8):
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
    return err[uint32](decodingError("jxs: entropy truncated"))
  var v: uint32 = 0
  for k in 0..<n:
    let p = r.bitPos + k
    let bit = (r.buf[p div 8] shr uint8(7 - (p mod 8))) and 1
    v = (v shl 1) or bit.uint32
  r.bitPos += n
  ok(v)

proc jxsBrBit(r: var JxsBitReader): ImageResult[uint8] =
  ## Single-bit read (MSB-first).
  if r.bitPos >= r.buf.len * 8:
    return err[uint8](decodingError("jxs: entropy truncated"))
  let p = r.bitPos
  let bit = (r.buf[p div 8] shr uint8(7 - (p mod 8))) and 1
  inc r.bitPos
  ok(bit)

func jxsBrRemaining*(r: JxsBitReader): int =
  r.buf.len * 8 - r.bitPos

func jxsBrConsumed*(r: JxsBitReader): int =
  (r.bitPos + 7) div 8

func jxsBrAtByte*(r: JxsBitReader): bool =
  r.bitPos mod 8 == 0

proc jxsBrAlign(r: var JxsBitReader) =
  ## Skip to the next byte boundary (Annex C `pad(8)`).
  if r.bitPos mod 8 != 0:
    r.bitPos += 8 - (r.bitPos mod 8)

proc jxsBrSkip(r: var JxsBitReader, n: int): ImageResult[bool] =
  ## Skip `n` whole filler bytes; must sit on a byte boundary.
  if r.bitPos mod 8 != 0:
    return err[bool](decodingError("jxs: filler skip off byte boundary"))
  if r.bitPos div 8 + n > r.buf.len:
    return err[bool](decodingError("jxs: filler skip past end"))
  r.bitPos += n * 8
  ok(true)

proc jxsVlc*(r: var JxsBitReader, rv, tv: int): ImageResult[int] =
  ## Annex C.7.1 Table C.15 signed-quantity VLC.
  let theta = max(rv - tv, 0)
  var x = 0
  while true:
    let bR = jxsBrBit(r)
    if not bR.ok: return err[int](bR.err)
    if bR.value == 0: break
    inc x
    if x >= 32:
      return err[int](decodingError("jxs: VLC lost synchronisation"))
  if x > 2 * theta: ok(x - theta)
  elif x > 0:
    if (x and 1) == 1: ok(-((x + 1) div 2))
    else: ok(x div 2)
  else: ok(0)

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

func jxsTruncTable*(q, r: uint8, bands: seq[JxsBand]): seq[uint8] =
  ## Per-band truncation positions for one precinct.
  var t: seq[uint8] = @[]
  for bd in bands:
    t.add(jxsTruncT(q, bd.gain, bd.priority, r))
  t

func jxsNcg*(wpb: uint32, ng: uint8): uint32 =
  ## Annex B.8: Ncg = ceil(Wpb/Ng).
  if ng == 0: 0 else: divCeil32(wpb, ng.uint32)

func jxsNs*(wpb: uint32, ng, ss: uint8): uint32 =
  ## Annex B.9: Ns = ceil(Wpb/(Ng*Ss)).
  let d = ng.uint32 * ss.uint32
  if d == 0: 0 else: divCeil32(wpb, d)

# ---------------------------------------------------------------------------
# Annex C.4/C.5 packet-body decode: significance, bitplane-count, data,
# optional sign sub-packets into per-band coefficient buffers.

type
  JxsBandCoef* = object
    wpb*: uint32
    numLines*: uint32
    v*: seq[uint32] # magnitudes, row-major
    s*: seq[uint8]  # signs (0/1)
    m*: seq[uint8]  # bitplane counts, ncg per line

  JxsPrecinctState* = object
    coefs*: seq[JxsBandCoef]
    sigFlags*: seq[uint8]
    sigStart*: seq[int]

  JxsPrecinctTop* = object
    lastM*: seq[seq[uint8]] # per-band last-line bitplane counts
    t*: seq[uint8]          # per-band truncation of precinct above

proc jxsInitState*(bands: seq[JxsBand], ng: uint8): JxsPrecinctState =
  var st: JxsPrecinctState
  for bd in bands:
    if not bd.exists:
      st.coefs.add(JxsBandCoef())
    else:
      let lines: uint32 =
        if bd.l1 > bd.l0: (bd.l1 - bd.l0).uint32 else: 0
      let ncg = jxsNcg(bd.wpb, ng)
      st.coefs.add(JxsBandCoef(wpb: bd.wpb, numLines: lines,
        v: newSeq[uint32](bd.wpb.int * lines.int),
        s: newSeq[uint8](bd.wpb.int * lines.int),
        m: newSeq[uint8](ncg.int * lines.int)))
  st

proc jxsCaptureTop*(bands: seq[JxsBand], ng: uint8, trunc: seq[uint8],
    st: JxsPrecinctState): JxsPrecinctTop =
  ## Table C.11 predecessor: last decoded line's M per band + T table.
  var top: JxsPrecinctTop
  top.t = trunc
  for bi, bd in bands:
    if not bd.exists or bd.l1 <= bd.l0 or bi >= st.coefs.len:
      top.lastM.add(@[])
      continue
    let ncg = jxsNcg(bd.wpb, ng).int
    let lastLine = (bd.l1 - bd.l0).int - 1
    let cf = st.coefs[bi]
    if cf.m.len >= (lastLine + 1) * ncg and ncg > 0:
      top.lastM.add(cf.m[lastLine * ncg ..< lastLine * ncg + ncg])
    else:
      top.lastM.add(newSeq[uint8](max(ncg, 0)))
  top

type
  JxsBodyOut* = object
    consumed*: int
    sigBytes*: int

proc jxsDecodePacketBody*(data: openArray[uint8],
    bands: seq[JxsBand], ng, ss, br, fs, rm: uint8,
    trunc: seq[uint8], dModes: seq[uint8],
    pkt: JxsPacketHdr, layout: seq[JxsPacketEntry],
    state: var JxsPrecinctState, top: Option[JxsPrecinctTop]):
    ImageResult[JxsBodyOut] =
  ## Annex C.4/C.5: significance → bitplane-count → data → [sign].
  ## Returns total bytes consumed (including Lcnt/Ldat/Lsgn filler).
  for e in layout:
    let bi = e.band.int
    if bi >= bands.len:
      return err[JxsBodyOut](decodingError("jxs: packet band out of range"))
    let bd = bands[bi]
    if not bd.exists:
      return err[JxsBodyOut](decodingError("jxs: packet on absent band"))
    if e.line < bd.l0 or e.line >= bd.l1:
      return err[JxsBodyOut](decodingError("jxs: packet line outside band"))
  let buf = @data
  var cursor = 0
  # --- significance ---
  var sigR = JxsBitReader(buf: buf, bitPos: 0)
  state.sigFlags = @[]
  state.sigStart = @[]
  for e in layout:
    let bi = e.band.int
    state.sigStart.add(state.sigFlags.len)
    if not bands[bi].exists: continue
    if pkt.dr == 0 and (dModes[bi] and 2) != 0:
      let ns = jxsNs(bands[bi].wpb, ng, ss).int
      for _ in 0..<ns:
        let zR = jxsBrBit(sigR)
        if not zR.ok: return err[JxsBodyOut](zR.err)
        state.sigFlags.add(zR.value)
  jxsBrAlign(sigR)
  let sigBytes = jxsBrConsumed(sigR)
  cursor += sigBytes
  # --- bitplane counts ---
  if cursor + pkt.lcnt.int > buf.len:
    return err[JxsBodyOut](decodingError("jxs: count sub-packet truncated"))
  var cntR = JxsBitReader(buf: buf[cursor ..< cursor + pkt.lcnt.int],
    bitPos: 0)
  let mMax: int =
    if br >= 8: 255 else: ((1 shl br.int) - 1)
  let mMaxC = min(mMax, 31)
  for ei, e in layout:
    let bi = e.band.int
    if not bands[bi].exists: continue
    let bd = bands[bi]
    let li = (e.line - bd.l0).int
    let ncg = jxsNcg(bd.wpb, ng).int
    let t = trunc[bi].int
    let dpb = dModes[bi]
    let cf = addr state.coefs[bi]
    if pkt.dr == 1:
      for g in 0..<ncg:
        let mR = jxsBrRead(cntR, br.int)
        if not mR.ok: return err[JxsBodyOut](mR.err)
        if mR.value.int > mMaxC:
          return err[JxsBodyOut](decodingError("jxs: raw count overflow"))
        cf.m[li * ncg + g] = mR.value.uint8
    elif (dpb and 1) == 0:
      let mtop = t
      for g in 0..<ncg:
        let sg = g div ss.int
        let z: uint8 =
          if (dpb and 2) != 0:
            if sg < state.sigFlags.len - state.sigStart[ei]:
              state.sigFlags[state.sigStart[ei] + sg]
            else: 0
          else: 0
        let dR =
          if (dpb and 2) == 0 or z == 0: jxsVlc(cntR, mtop, t)
          else: ok(0)
        if not dR.ok: return err[JxsBodyOut](dR.err)
        let m = mtop + dR.value
        if m < 0 or m > mMaxC:
          return err[JxsBodyOut](decodingError("jxs: count out of range"))
        cf.m[li * ncg + g] = m.uint8
    else:
      let firstLine = e.line < bd.l0 + 1
      if firstLine and top.isNone:
        return err[JxsBodyOut](decodingError(
          "jxs: vertical prediction at slice top"))
      let ttop =
        if firstLine:
          if top.get.t.len > bi: top.get.t[bi].int else: 0
        else: t
      let teff = max(t, ttop)
      let prevLi =
        if firstLine: 0 else: ((e.line - 1) - bd.l0).int
      for g in 0..<ncg:
        let sg = g div ss.int
        let z: uint8 =
          if (dpb and 2) != 0:
            if sg < state.sigFlags.len - state.sigStart[ei]:
              state.sigFlags[state.sigStart[ei] + sg]
            else: 0
          else: 0
        let mAbove: int =
          if firstLine:
            if top.get.lastM.len > bi and top.get.lastM[bi].len > g:
              top.get.lastM[bi][g].int
            else: 0
          else: cf.m[prevLi * ncg + g].int
        let mtop = max(mAbove, teff)
        var dR: ImageResult[int]
        if (dpb and 2) == 0 or z == 0:
          dR = jxsVlc(cntR, mtop, t)
        elif rm == 0:
          dR = ok(0)
        else:
          dR = ok(t - mtop)
        if not dR.ok: return err[JxsBodyOut](dR.err)
        let m = mtop + dR.value
        if m < 0 or m > mMaxC:
          return err[JxsBodyOut](decodingError("jxs: count out of range"))
        cf.m[li * ncg + g] = m.uint8
  jxsBrAlign(cntR)
  if jxsBrConsumed(cntR) > pkt.lcnt.int:
    return err[JxsBodyOut](decodingError("jxs: count overran Lcnt"))
  cursor += pkt.lcnt.int
  # --- data ---
  if cursor + pkt.ldat.int > buf.len:
    return err[JxsBodyOut](decodingError("jxs: data sub-packet truncated"))
  var datR = JxsBitReader(buf: buf[cursor ..< cursor + pkt.ldat.int],
    bitPos: 0)
  var tails = newSeq[seq[uint32]](layout.len)
  for ei, e in layout:
    let bi = e.band.int
    if not bands[bi].exists: continue
    let bd = bands[bi]
    let li = (e.line - bd.l0).int
    let ncg = jxsNcg(bd.wpb, ng).int
    let t = trunc[bi].uint32
    let wpb = bd.wpb.int
    let ngI = ng.int
    let cf = addr state.coefs[bi]
    let lineOff = li * wpb
    let tailLen = ncg * ngI - wpb
    tails[ei] = newSeq[uint32](max(tailLen, 0))
    for g in 0..<ncg:
      let m = cf.m[li * ncg + g].uint32
      let base = g * ngI
      let lo = min(base, wpb)
      let inBand = min(base + ngI, wpb) - lo
      for k in 0..<inBand: cf.v[lineOff + lo + k] = 0
      if m > t:
        if fs == 0:
          var k = 0
          while k < ngI:
            let n = min(ngI - k, 32)
            let bR = jxsBrRead(datR, n)
            if not bR.ok: return err[JxsBodyOut](bR.err)
            for i in 0..<n:
              let bit = (bR.value shr (n - 1 - i)) and 1
              if base + k + i < wpb:
                cf.s[lineOff + base + k + i] = bit.uint8
            k += n
        let nplanes = (m - t).int
        for plane in countdown(nplanes - 1, 0):
          var k = 0
          while k < ngI:
            let n = min(ngI - k, 32)
            let bR = jxsBrRead(datR, n)
            if not bR.ok: return err[JxsBodyOut](bR.err)
            for i in 0..<n:
              let bit = (bR.value shr (n - 1 - i)) and 1
              let xp = base + k + i
              if xp < wpb:
                cf.v[lineOff + xp] = cf.v[lineOff + xp] or
                  (bit shl plane)
              else:
                tails[ei][xp - wpb] = tails[ei][xp - wpb] or
                  (bit shl plane)
            k += n
  jxsBrAlign(datR)
  if jxsBrConsumed(datR) > pkt.ldat.int:
    return err[JxsBodyOut](decodingError("jxs: data overran Ldat"))
  cursor += pkt.ldat.int
  # --- sign ---
  if fs == 1:
    if cursor + pkt.lsgn.int > buf.len:
      return err[JxsBodyOut](decodingError("jxs: sign sub-packet truncated"))
    var sgnR = JxsBitReader(buf: buf[cursor ..< cursor + pkt.lsgn.int],
      bitPos: 0)
    for ei, e in layout:
      let bi = e.band.int
      if not bands[bi].exists: continue
      let bd = bands[bi]
      let li = (e.line - bd.l0).int
      let ncg = jxsNcg(bd.wpb, ng).int
      let wpb = bd.wpb.int
      let ngI = ng.int
      let cf = addr state.coefs[bi]
      let lineOff = li * wpb
      for g in 0..<ncg:
        for k in 0..<ngI:
          let xp = g * ngI + k
          if xp >= wpb:
            if tails[ei][xp - wpb] != 0:
              let bR = jxsBrBit(sgnR)
              if not bR.ok: return err[JxsBodyOut](bR.err)
          elif cf.v[lineOff + xp] != 0:
            let bR = jxsBrBit(sgnR)
            if not bR.ok: return err[JxsBodyOut](bR.err)
            cf.s[lineOff + xp] = bR.value
    jxsBrAlign(sgnR)
    if jxsBrConsumed(sgnR) > pkt.lsgn.int:
      return err[JxsBodyOut](decodingError("jxs: sign overran Lsgn"))
    cursor += pkt.lsgn.int
  ok(JxsBodyOut(consumed: cursor, sigBytes: sigBytes))

# ---------------------------------------------------------------------------
# Annex E 5/3 wavelet transform. Inverse follows Table E.1 order
# (horizontal synthesis first, vertical last on joint levels); forward
# follows Table E.8 (vertical first). Lifting uses floor division so
# negative sums match the spec's arithmetic shifts on every backend.
# (jxsFDiv2/jxsFDiv4/jxsFDivPow2 live with the foundations above.)

proc jxsSynthLine*(low, high: openArray[int], outP: var openArray[int]) =
  ## Table E.6 one-row inverse lift: low/high → interleaved row.
  let nl = low.len
  let nh = high.len
  outP[0] = low[0] - jxsFDiv4(high[0] + high[0] + 2)
  for n in 1..<nh:
    outP[2*n] = low[n] - jxsFDiv4(high[n-1] + high[n] + 2)
  if nl > nh:
    outP[2*nh] = low[nh] - jxsFDiv4(high[nh-1] + high[nh-1] + 2)
  for n in 0..<nh-1:
    outP[2*n+1] = high[n] + jxsFDiv2(outP[2*n] + outP[2*n+2])
  if nh >= 1:
    let last = nh - 1
    let right = if nl > nh: outP[2*last+2] else: outP[2*last]
    outP[2*last+1] = high[last] + jxsFDiv2(outP[2*last] + right)

proc jxsAnalyseLine*(x: openArray[int], low, high: var openArray[int]) =
  ## Table E.12 one-row forward lift: interleaved row → low/high.
  let nl = low.len
  let nh = high.len
  for n in 0..<nh-1:
    high[n] = x[2*n+1] - jxsFDiv2(x[2*n] + x[2*n+2])
  if nh >= 1:
    let last = nh - 1
    let right = if nl > nh: x[2*last+2] else: x[2*last]
    high[last] = x[2*last+1] - jxsFDiv2(x[2*last] + right)
    low[0] = x[0] + jxsFDiv4(high[0] + high[0] + 2)
    for n in 1..<nh:
      low[n] = x[2*n] + jxsFDiv4(high[n-1] + high[n] + 2)
    if nl > nh:
      low[nh] = x[2*nh] + jxsFDiv4(high[nh-1] + high[nh-1] + 2)

proc jxsSynthRows*(buf: var seq[int], w, h: int) =
  ## Table E.6 vertical pass in place (even rows then odd rows).
  for y in countup(0, h-1, 2):
    for x in 0..<w:
      let a = if y > 0: buf[(y-1)*w+x] else: buf[(y+1)*w+x]
      let b = if y+1 < h: buf[(y+1)*w+x] else: buf[(y-1)*w+x]
      buf[y*w+x] = buf[y*w+x] - jxsFDiv4(a + b + 2)
  for y in countup(1, h-1, 2):
    for x in 0..<w:
      let a = buf[(y-1)*w+x]
      let b = if y+1 < h: buf[(y+1)*w+x] else: a
      buf[y*w+x] = buf[y*w+x] + jxsFDiv2(a + b)

proc jxsAnalyseRows*(buf: var seq[int], w, h: int) =
  ## Table E.11 vertical forward pass in place (odd rows then even).
  for y in countup(1, h-1, 2):
    for x in 0..<w:
      let a = buf[(y-1)*w+x]
      let b = if y+1 < h: buf[(y+1)*w+x] else: a
      buf[y*w+x] = buf[y*w+x] - jxsFDiv2(a + b)
  for y in countup(0, h-1, 2):
    for x in 0..<w:
      let a = if y > 0: buf[(y-1)*w+x] else: buf[(y+1)*w+x]
      let b = if y+1 < h: buf[(y+1)*w+x] else: buf[(y-1)*w+x]
      buf[y*w+x] = buf[y*w+x] + jxsFDiv4(a + b + 2)

func jxsBandDims*(wc, hc: int, dx, dy: uint32, tx, ty: bool):
    tuple[w, h: int] =
  ## Annex B.2 band dimensions in a component grid.
  let w =
    if not tx:
      if dx == 0: wc else: divCeil32(wc.uint32, 1'u32 shl dx).int
    else:
      let dm: uint32 = if dx == 0: 1 else: 1'u32 shl (dx - 1)
      divCeil32(wc.uint32, dm).int div 2
  let h =
    if not ty:
      if dy == 0: hc else: divCeil32(hc.uint32, 1'u32 shl dy).int
    else:
      let dm: uint32 = if dy == 0: 1 else: 1'u32 shl (dy - 1)
      divCeil32(hc.uint32, dm).int div 2
  (w, h)

proc jxsInverse2d*(w, h: int, ll, hl, lh, hh: openArray[int],
    outP: var seq[int]): ImageResult[bool] =
  ## Table E.1 joint level: horizontal synthesis on both row halves,
  ## then vertical synthesis in place.
  if w < 2 or h < 2:
    return err[bool](decodingError("jxs: DWT block below 2x2"))
  let llW = (w + 1) div 2
  let hlW = w div 2
  let llH = (h + 1) div 2
  let lhH = h div 2
  if ll.len != llW*llH or hl.len != hlW*llH or lh.len != llW*lhH or
      hh.len != hlW*lhH or outP.len != w*h:
    return err[bool](decodingError("jxs: DWT sub-band size mismatch"))
  for y in 0..<h:
    let n = y div 2
    if y mod 2 == 0:
      jxsSynthLine(ll.toOpenArray(n*llW, (n+1)*llW-1),
        hl.toOpenArray(n*hlW, (n+1)*hlW-1),
        outP.toOpenArray(y*w, (y+1)*w-1))
    else:
      jxsSynthLine(lh.toOpenArray(n*llW, (n+1)*llW-1),
        hh.toOpenArray(n*hlW, (n+1)*hlW-1),
        outP.toOpenArray(y*w, (y+1)*w-1))
  jxsSynthRows(outP, w, h)
  ok(true)

proc jxsForward2d*(w, h: int, input: openArray[int], ll, hl, lh, hh:
    var openArray[int]): ImageResult[bool] =
  ## Table E.8 joint level: vertical analysis, then horizontal halves.
  if w < 2 or h < 2:
    return err[bool](decodingError("jxs: DWT block below 2x2"))
  let llW = (w + 1) div 2
  let hlW = w div 2
  let llH = (h + 1) div 2
  let lhH = h div 2
  if input.len != w*h or ll.len != llW*llH or hl.len != hlW*llH or
      lh.len != llW*lhH or hh.len != hlW*lhH:
    return err[bool](decodingError("jxs: DWT sub-band size mismatch"))
  var blk = @input
  jxsAnalyseRows(blk, w, h)
  for y in 0..<h:
    let n = y div 2
    if y mod 2 == 0:
      jxsAnalyseLine(blk.toOpenArray(y*w, (y+1)*w-1),
        ll.toOpenArray(n*llW, (n+1)*llW-1),
        hl.toOpenArray(n*hlW, (n+1)*hlW-1))
    else:
      jxsAnalyseLine(blk.toOpenArray(y*w, (y+1)*w-1),
        lh.toOpenArray(n*llW, (n+1)*llW-1),
        hh.toOpenArray(n*hlW, (n+1)*hlW-1))
  ok(true)

proc jxsInverseCascade*(wc, hc: int, nlx, nly: uint8,
    bands: seq[seq[int]], outP: var seq[int]): ImageResult[bool] =
  ## Table E.1 cascade over per-component β buffers (local indexing).
  if nlx == 0 and nly == 0:
    if bands.len == 0 or bands[0].len != wc*hc or outP.len != wc*hc:
      return err[bool](decodingError("jxs: DWT copy size mismatch"))
    outP = bands[0]
    return ok(true)
  if nly > nlx:
    return err[bool](unsupportedError(ukGenericFeature,
      "jxs: NL,y > NL,x cascade"))
  if wc < 2 or hc < 2:
    return err[bool](decodingError("jxs: DWT plane below 2x2"))
  let nBeta = jxsNBeta(nlx, nly).int
  if bands.len != nBeta:
    return err[bool](decodingError("jxs: DWT band count mismatch"))
  proc findBand(dx, dy: uint32, tx, ty: bool): int =
    for b in 0..<nBeta:
      let (ddx, ddy, ttx, tty) = jxsBetaLevels(b.uint32, nlx, nly)
      if ddx == dx and ddy == dy and ttx == tx and tty == ty: return b
    -1
  let dMin = min(nlx, nly)
  var curW, curH: int
  (curW, curH) = jxsBandDims(wc, hc, nlx.uint32, nly.uint32, false, false)
  let ll0 = findBand(nlx.uint32, nly.uint32, false, false)
  if ll0 < 0 or bands[ll0].len != curW*curH:
    return err[bool](decodingError("jxs: DWT LL band missing"))
  var curLL = bands[ll0]
  # Phase 1: pure horizontal levels dx = nlx .. dMin+1.
  var dxCur = nlx
  while dxCur > dMin:
    let hlB = findBand(dxCur.uint32, nly.uint32, true, false)
    if hlB < 0:
      return err[bool](decodingError("jxs: DWT HL band missing"))
    let (hlW, hlH) = jxsBandDims(wc, hc, dxCur.uint32, nly.uint32,
      true, false)
    if bands[hlB].len != hlW*hlH or hlH != curH:
      return err[bool](decodingError("jxs: DWT HL size mismatch"))
    let (nxW, nxH) = jxsBandDims(wc, hc, (dxCur-1).uint32, nly.uint32,
      false, false)
    var nextLL = newSeq[int](nxW*nxH)
    for y in 0..<curH:
      jxsSynthLine(curLL.toOpenArray(y*curW, (y+1)*curW-1),
        bands[hlB].toOpenArray(y*hlW, (y+1)*hlW-1),
        nextLL.toOpenArray(y*nxW, (y+1)*nxW-1))
    curLL = move(nextLL)
    curW = nxW
    curH = nxH
    dec dxCur
  # Phase 2: joint levels d = dMin .. 1.
  var d = dMin
  while d > 0:
    let (eW, eH) = jxsBandDims(wc, hc, d.uint32, d.uint32, false, false)
    if (curW, curH) != (eW, eH):
      return err[bool](decodingError("jxs: DWT pre-step size mismatch"))
    let hlB = findBand(d.uint32, d.uint32, true, false)
    let lhB = findBand(d.uint32, d.uint32, false, true)
    let hhB = findBand(d.uint32, d.uint32, true, true)
    if hlB < 0 or lhB < 0 or hhB < 0:
      return err[bool](decodingError("jxs: DWT joint band missing"))
    let (nxW, nxH) = jxsBandDims(wc, hc, (d-1).uint32, (d-1).uint32,
      false, false)
    var nextLL = newSeq[int](nxW*nxH)
    let r = jxsInverse2d(nxW, nxH, curLL, bands[hlB], bands[lhB],
      bands[hhB], nextLL)
    if not r.ok: return err[bool](r.err)
    curLL = move(nextLL)
    curW = nxW
    curH = nxH
    dec d
  if (curW, curH) != (wc, hc):
    return err[bool](decodingError("jxs: DWT final size mismatch"))
  outP = move(curLL)
  ok(true)

proc jxsForwardCascade*(wc, hc: int, nlx, nly: uint8,
    input: openArray[int]): ImageResult[seq[seq[int]]] =
  ## Table E.8 forward cascade (test-encoder side).
  if nlx == 0 and nly == 0:
    return ok(@[@input])
  if nly > nlx:
    return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
      "jxs: NL,y > NL,x cascade"))
  let nBeta = jxsNBeta(nlx, nly).int
  var bands = newSeq[seq[int]](nBeta)
  proc findBand(dx, dy: uint32, tx, ty: bool): int =
    for b in 0..<nBeta:
      let (ddx, ddy, ttx, tty) = jxsBetaLevels(b.uint32, nlx, nly)
      if ddx == dx and ddy == dy and ttx == tx and tty == ty: return b
    -1
  var curLL = @input
  var curW = wc
  var curH = hc
  let dMin = min(nlx, nly)
  # Phase A: joint levels d = 1 .. dMin. Only HL/LH/HH land in band
  # slots; the LL threads through to the next level.
  var d: uint8 = 1
  while d <= dMin:
    let hlB = findBand(d.uint32, d.uint32, true, false)
    let lhB = findBand(d.uint32, d.uint32, false, true)
    let hhB = findBand(d.uint32, d.uint32, true, true)
    if hlB < 0 or lhB < 0 or hhB < 0:
      return err[seq[seq[int]]](decodingError("jxs: fwd joint band missing"))
    let llW = (curW + 1) div 2
    let hlW = curW div 2
    let llH = (curH + 1) div 2
    let lhH = curH div 2
    var ll = newSeq[int](llW*llH)
    var hl = newSeq[int](hlW*llH)
    var lh = newSeq[int](llW*lhH)
    var hh = newSeq[int](hlW*lhH)
    let r = jxsForward2d(curW, curH, curLL, ll.toOpenArray(0, ll.len-1),
      hl.toOpenArray(0, hl.len-1), lh.toOpenArray(0, lh.len-1),
      hh.toOpenArray(0, hh.len-1))
    if not r.ok: return err[seq[seq[int]]](r.err)
    bands[hlB] = hl
    bands[lhB] = lh
    bands[hhB] = hh
    curLL = ll
    curW = llW
    curH = llH
    inc d
  # Phase B: pure horizontal levels dx = dMin+1 .. nlx.
  var dxCur = dMin + 1
  while dxCur <= nlx:
    let hlB = findBand(dxCur.uint32, nly.uint32, true, false)
    if hlB < 0:
      return err[seq[seq[int]]](decodingError("jxs: fwd HL band missing"))
    let nextW = (curW + 1) div 2
    let hlW = curW div 2
    var ll = newSeq[int](nextW*curH)
    var hl = newSeq[int](hlW*curH)
    for y in 0..<curH:
      jxsAnalyseLine(curLL.toOpenArray(y*curW, (y+1)*curW-1),
        ll.toOpenArray(y*nextW, (y+1)*nextW-1),
        hl.toOpenArray(y*hlW, (y+1)*hlW-1))
    bands[hlB] = hl
    curLL = ll
    curW = nextW
    inc dxCur
  # Final LL lands in the LL_{nlx,nly} slot.
  let llB = findBand(nlx.uint32, nly.uint32, false, false)
  if llB < 0:
    return err[seq[seq[int]]](decodingError("jxs: fwd LL band missing"))
  bands[llB] = curLL
  ok(bands)

proc jxsDequantDeadzone*(cf: JxsBandCoef, t, ng: uint8,
    outP: var seq[int]) =
  ## Annex D.2 Table D.1.
  let wpb = cf.wpb.int
  let ngI = ng.int
  let tU = t.uint32
  let r: uint32 = (1'u32 shl tU) shr 1
  for line in 0..<cf.numLines.int:
    let ncg = if ngI == 0: 0 else: (wpb + ngI - 1) div ngI
    for x in 0..<wpb:
      let g = if ngI == 0: 0 else: x div ngI
      let vv = cf.v[line * wpb + x]
      let mm = if g < ncg: cf.m[line * ncg + g].uint32 else: 0'u32
      let sgn = cf.s[line * wpb + x]
      if mm > tU and vv != 0:
        let mag = (vv shl tU) + r
        outP[line * wpb + x] = if sgn == 0: mag.int else: -mag.int
      else:
        outP[line * wpb + x] = 0

proc jxsDequantUniform*(cf: JxsBandCoef, t, ng: uint8,
    outP: var seq[int]) =
  ## Annex D.3 Table D.2 (Neumann-series reconstruction).
  let wpb = cf.wpb.int
  let ngI = ng.int
  let tU = t.uint32
  for line in 0..<cf.numLines.int:
    let ncg = if ngI == 0: 0 else: (wpb + ngI - 1) div ngI
    for x in 0..<wpb:
      let g = if ngI == 0: 0 else: x div ngI
      let vv = cf.v[line * wpb + x]
      let mm = if g < ncg: cf.m[line * ncg + g].uint32 else: 0'u32
      let sgn = cf.s[line * wpb + x]
      if mm > tU and vv != 0:
        var phi: uint64 = vv.uint64 shl tU
        let zeta = mm - tU + 1
        var rho: uint64 = 0
        if zeta > 0:
          while phi > 0:
            rho += phi
            if zeta >= 64: break
            phi = phi shr zeta
        outP[line * wpb + x] =
          if sgn == 0: rho.int else: -rho.int
      else:
        outP[line * wpb + x] = 0

proc jxsDequantPrecinct*(qpih: uint8, bands: seq[JxsBand], ng: uint8,
    trunc: seq[uint8], coefs: seq[JxsBandCoef], fq: uint8):
    seq[seq[int]] =
  ## Per-band dequant + `c << Fq` (E.3 Table E.13).
  var res: seq[seq[int]] = @[]
  for b, cf in coefs:
    if b >= bands.len or not bands[b].exists:
      res.add(@[])
      continue
    var buf = newSeq[int](cf.wpb.int * cf.numLines.int)
    let t = if b < trunc.len: trunc[b] else: 0
    if qpih == 1: jxsDequantUniform(cf, t, ng, buf)
    else: jxsDequantDeadzone(cf, t, ng, buf)
    if fq != 0:
      for i in 0..<buf.len: buf[i] = buf[i] shl fq.int
    res.add(buf)
  res


const
  JxsBoxFtyp* = 0x66747970'u32
  JxsBoxHeader* = 0x6A787368'u32 # 'jxsh'
  JxsBoxIhdr* = 0x69686472'u32   # 'ihdr'
  JxsBoxColr* = 0x636F6C72'u32   # 'colr'
  JxsBrandJxs* = 0x6A787320'u32  # 'jxs '

type
  JxsFileMeta* = object
    csOff*: int
    csLen*: int
    ihdrW*: uint32
    ihdrH*: uint32
    ihdrNc*: int
    ihdrBd*: int # -1 = varying (BPC 0xFF)
    matrix*: int # -1 = no CICP box, else H.273 code point
    fullRange*: bool

proc jxsBoxAt(data: openArray[uint8], p: int):
    tuple[tb: uint32, hdr, plen: int, ok: bool] =
  ## Parse one box header at `p` (LBox/TBox/[XLBox]).
  if p + 8 > data.len: return (0'u32, 0, 0, false)
  let lb = u32be(data, p)
  let tb = u32be(data, p+4)
  if lb == 1:
    if p + 16 > data.len: return (0'u32, 0, 0, false)
    if u32be(data, p+8) != 0: return (0'u32, 0, 0, false)
    let lo = u32be(data, p+12)
    if lo < 16: return (0'u32, 0, 0, false)
    (tb, 16, lo.int - 16, true)
  elif lb == 0:
    (tb, 8, data.len - (p + 8), true)
  elif lb < 8:
    (0'u32, 0, 0, false)
  else:
    (tb, 8, lb.int - 8, true)

proc parseJxsFile*(data: openArray[uint8]): ImageResult[JxsFileMeta] =
  ## Part-3 box walk: Signature + FileType + Header(jxsh) + jp2c.
  ## Returns codestream location, ihdr geometry and the first CICP
  ## colour description (matrix/full-range) when present.
  if not isJxsFile(data):
    return err[JxsFileMeta](decodingError("jxs: not a JXS file"))
  var meta: JxsFileMeta
  meta.matrix = -1
  meta.ihdrBd = -1
  var p = 12 # past Signature
  var haveFtyp = false
  var jxshOff = -1
  var jxshLen = 0
  var csOff = -1
  var csLen = 0
  while p + 8 <= data.len:
    let (tb, hdr, plen, ok) = jxsBoxAt(data, p)
    if not ok or plen < 0 or p + hdr + plen > data.len:
      return err[JxsFileMeta](decodingError("jxs: bad top-level box"))
    if tb == JxsBoxFtyp:
      if plen < 8:
        return err[JxsFileMeta](decodingError("jxs: bad ftyp"))
      # major(4) + minor(4) + compat list: require 'jxs ' compat
      var compat = false
      var q = p + hdr + 8
      while q + 4 <= p + hdr + plen:
        if u32be(data, q) == JxsBrandJxs: compat = true
        q += 4
      if not compat:
        return err[JxsFileMeta](unsupportedError(ukFormat,
          "jxs: ftyp without jxs brand"))
      haveFtyp = true
    elif tb == JxsBoxHeader:
      if jxshOff >= 0:
        return err[JxsFileMeta](decodingError("jxs: duplicate Header"))
      jxshOff = p + hdr
      jxshLen = plen
    elif tb == JxsCodeStreamBox:
      if csOff < 0:
        csOff = p + hdr
        csLen = plen
    p += hdr + plen
  if not haveFtyp:
    return err[JxsFileMeta](decodingError("jxs: file without FileType"))
  if jxshOff < 0:
    return err[JxsFileMeta](decodingError("jxs: file without Header"))
  if csOff < 0:
    return err[JxsFileMeta](decodingError("jxs: file has no codestream"))
  # inner boxes of jxsh: ihdr first, then colr/cdef/...
  var q = jxshOff
  let qEnd = jxshOff + jxshLen
  var firstInner = true
  var haveIhdr = false
  var haveColr = false
  while q + 8 <= qEnd:
    let (tb, hdr, plen, ok) = jxsBoxAt(data, q)
    if not ok or plen < 0 or q + hdr + plen > qEnd:
      return err[JxsFileMeta](decodingError("jxs: bad Header box"))
    if firstInner and tb != JxsBoxIhdr:
      return err[JxsFileMeta](decodingError(
        "jxs: Image Header shall be first in Header"))
    firstInner = false
    if tb == JxsBoxIhdr:
      if haveIhdr:
        return err[JxsFileMeta](decodingError("jxs: duplicate ihdr"))
      if plen != 14:
        return err[JxsFileMeta](decodingError("jxs: ihdr must be 14"))
      let d = q + hdr
      meta.ihdrH = u32be(data, d)
      meta.ihdrW = u32be(data, d+4)
      meta.ihdrNc = int(u16be(data, d+8))
      let bpc = data[d+10]
      let cc = data[d+11]
      if cc != 12:
        return err[JxsFileMeta](unsupportedError(ukFormat,
          "jxs: ihdr compression is not JPEG XS"))
      if bpc == 0xFF:
        meta.ihdrBd = -1
      elif (bpc and 0x80) != 0:
        return err[JxsFileMeta](unsupportedError(ukGenericFeature,
          "jxs: signed samples"))
      else:
        meta.ihdrBd = int(bpc and 0x7F) + 1
      haveIhdr = true
    elif tb == JxsBoxColr and not haveColr:
      # first colr box decides; CICP (METH=5) carries matrix/range.
      haveColr = true
      let d = q + hdr
      if plen >= 10 and data[d] == 5:
        meta.matrix = int(u16be(data, d+7))
        meta.fullRange = (data[d+9] and 0x80) != 0
    q += hdr + plen
  if not haveIhdr:
    return err[JxsFileMeta](decodingError("jxs: Header without ihdr"))
  if meta.ihdrW == 0 or meta.ihdrH == 0 or meta.ihdrNc <= 0:
    return err[JxsFileMeta](decodingError("jxs: bad ihdr geometry"))
  meta.csOff = csOff
  meta.csLen = csLen
  ok(meta)

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


type
  JxsNlt* = object
    ## Parsed NLT marker (Annex A.4.6 Table A.16).
    case kind*: uint8
    of 1: # quadratic (Annex G.4)
      dco*: int
    of 2: # extended (Annex G.5)
      t1*: uint32
      t2*: uint32
      e*: uint8
    else: discard

proc jxsParseNlt*(body: openArray[uint8]): ImageResult[JxsNlt] =
  ## Table A.16: Tnlt=1 → σ:α DCO (Lnlt=5); Tnlt=2 → T1+T2+E (Lnlt=12).
  if body.len == 0:
    return err[JxsNlt](decodingError("jxs: empty NLT body"))
  case body[0]
  of 1:
    if body.len != 3:
      return err[JxsNlt](decodingError("jxs: NLT Tnlt=1 needs 3 bytes"))
    let packed = (body[1].uint16 shl 8) or body[2].uint16
    let sigma = (packed shr 15) and 1
    let alpha = (packed and 0x7FFF).int
    ok(JxsNlt(kind: 1, dco: alpha - sigma.int * (1 shl 15)))
  of 2:
    if body.len != 10:
      return err[JxsNlt](decodingError("jxs: NLT Tnlt=2 needs 10 bytes"))
    let t1 = (body[1].uint32 shl 24) or (body[2].uint32 shl 16) or
      (body[3].uint32 shl 8) or body[4].uint32
    let t2 = (body[5].uint32 shl 24) or (body[6].uint32 shl 16) or
      (body[7].uint32 shl 8) or body[8].uint32
    let e = body[9]
    if t1 == 0 or t2 == 0 or t2 <= t1:
      return err[JxsNlt](decodingError("jxs: NLT needs 0 < T1 < T2"))
    if e < 1 or e > 4:
      return err[JxsNlt](decodingError("jxs: NLT E range 1..4"))
    if t1 > (1'u32 shl 20) - 1 or t2 > (1'u32 shl 20) - 1:
      # Bw ≤ 20 everywhere; wider thresholds cannot be addressed.
      return err[JxsNlt](decodingError("jxs: NLT thresholds exceed 2^20-1"))
    ok(JxsNlt(kind: 2, t1: t1, t2: t2, e: e))
  else:
    return err[JxsNlt](unsupportedError(ukGenericFeature,
      "jxs: reserved NLT Tnlt"))

func jxsNltQuad*(v, bw, bc: int, dco: int): int =
  ## Annex G.4 Table G.3 scalar kernel (i64: v² overflows 32 bits).
  let zeta = 2 * bw - bc
  let m = (1 shl bc) - 1
  let dcB = 1 shl (bw - 1)
  let bwMax = (1 shl bw) - 1
  let zu = max(zeta, 0)
  let half = if zu == 0: 0 else: 1 shl (zu - 1)
  var t = v + dcB
  if t < 0: t = 0 elif t > bwMax: t = bwMax
  var q = t * t
  if zu > 0: q = (q + half) shr zu
  q += dco
  if q < 0: q = 0 elif q > m: q = m
  q

func jxsNltExt*(v: int, bw, bc: uint8, t1, t2: uint32, e: uint8): int =
  ## Annex G.5 Table G.4 scalar kernel.
  let bwi = bw.int
  let m = (1 shl bc.int) - 1
  let dcB = 1 shl (bw.int - 1)
  let bwMax = (1 shl bw.int) - 1
  let b2 = t1.int * t1.int
  let shAE = 2 * bwi - 2 - 2 * e.int
  let a1 = b2 + (t1.int shl (bwi - e.int)) + (1 shl shAE)
  let b1 = t1.int + (1 shl (bwi - e.int - 1))
  let a3 = b2 + (t2.int shl (bwi - e.int)) - (1 shl shAE)
  let b3 = t2.int - (1 shl (bwi - e.int - 1))
  let zeta = 2 * bwi - bc.int
  let zu = max(zeta, 0)
  let half = if zu == 0: 0 else: 1 shl (zu - 1)
  var t = v + dcB
  if t < t1.int:
    t = b1 - t
    if t < 0: t = 0 elif t > bwMax: t = bwMax
    t = a1 - t * t
  elif t < t2.int:
    t = (t shl (bwi - e.int)) + b2
  else:
    t -= b3
    if t < 0: t = 0 elif t > bwMax: t = bwMax
    t = a3 + t * t
  if zu > 0: t = (t + half) shr zu
  if t < 0: t = 0 elif t > m: t = m
  t

proc jxsNltOut*(omega: seq[int], bw, bc: uint8,
    nlt: JxsNlt): ImageResult[seq[uint8]] =
  ## Annex G.4/G.5 output scaling + clip + pack.
  if bw < 8 or bw > 20 or bc < 8 or bc > 16:
    return err[seq[uint8]](decodingError("jxs: bad (Bw,B[i]) for NLT"))
  var res = newSeq[uint8](omega.len * (if bc == 8: 1 else: 2))
  case nlt.kind
  of 1:
    for i, v in omega:
      let t = jxsNltQuad(v, bw.int, bc.int, nlt.dco)
      if bc == 8: res[i] = t.uint8
      else:
        res[2*i] = (t and 0xFF).uint8
        res[2*i+1] = ((t shr 8) and 0xFF).uint8
  of 2:
    for i, v in omega:
      let t = jxsNltExt(v, bw, bc, nlt.t1, nlt.t2, nlt.e)
      if bc == 8: res[i] = t.uint8
      else:
        res[2*i] = (t and 0xFF).uint8
        res[2*i+1] = ((t shr 8) and 0xFF).uint8
  else:
    return err[seq[uint8]](decodingError("jxs: bad NLT kind"))
  ok(res)

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
      let nR = jxsParseNlt(h.nlt)
      if not nR.ok: return err[JxsHeaders](nR.err)
      h.hasNlt = true
      h.nltKind = nR.value.kind
      if nR.value.kind == 1:
        h.nltDco = nR.value.dco
      elif nR.value.kind == 2:
        h.nltT1 = nR.value.t1
        h.nltT2 = nR.value.t2
        h.nltE = nR.value.e
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


# ---------------------------------------------------------------------------
# Full-picture decode pipeline: precincts → gather → cascade → colour
# → Annex G output → DynamicImage. Vertical slice: uniform depth,
# full-res, Cpih 0/1 (gray/RCT), no NLT, no Star-Tetrix, no CWD.

func jxsFDivPow2*(a: int, n: int): int =
  ## floor(a / 2^n), backend-independent.
  if n == 0: a
  elif a >= 0: a shr n
  else: -(((-a) + (1 shl n) - 1) div (1 shl n))

proc jxsLinearOut*(omega: seq[int], bw, bc: uint8): ImageResult[seq[uint8]] =
  ## Annex G.3 Table G.2 linear output scaling + clip + pack.
  if bw < bc or bc < 8 or bc > 16:
    return err[seq[uint8]](decodingError("jxs: bad (Bw,B[i]) for output"))
  let zeta = (bw - bc).int
  let m = (1 shl bc.int) - 1
  let dc = 1 shl (bw.int - 1)
  var res = newSeq[uint8](omega.len * (if bc == 8: 1 else: 2))
  for i, v in omega:
    var t = v + dc
    if zeta > 0:
      t = jxsFDivPow2(t + (1 shl (zeta - 1)), zeta)
    if t < 0: t = 0
    elif t > m: t = m
    if bc == 8: res[i] = t.uint8
    else:
      res[2*i] = (t and 0xFF).uint8
      res[2*i+1] = ((t shr 8) and 0xFF).uint8
  ok(res)


proc jxsInverseRct*(planes: var seq[seq[int]]) =
  ## Annex F.3 Table F.2 in place on the first three planes.
  let n = planes[0].len
  for x in 0..<n:
    let i0 = planes[0][x]
    let i1 = planes[1][x]
    let i2 = planes[2][x]
    let o1 = i0 - jxsFDiv4(i1 + i2)
    planes[0][x] = o1 + i2
    planes[1][x] = o1
    planes[2][x] = o1 + i1

proc jxsForwardRct*(planes: var seq[seq[int]]) =
  ## Annex F.4 Table F.3 (test-encoder side).
  let n = planes[0].len
  for x in 0..<n:
    let r = planes[0][x]
    let g = planes[1][x]
    let b = planes[2][x]
    planes[0][x] = jxsFDiv4(r + 2*g + b)
    planes[1][x] = b - g
    planes[2][x] = r - g

func jxsYcbcrPixel*(y, cb, cr: int, bd: uint8, fullRange = false):
    tuple[r, g, b: int] =
  ## BT.709 YCbCr→RGB, integer-exact. `fullRange` selects full swing
  ## (CICP V flag); otherwise limited studio swing. Bare codestreams
  ## carry no colour description; limited is the broadcast default.
  ## 8-bit is the native rail-exact kernel; deeper depths downscale
  ## into it and replicate out (`v*257`), exact at black/white and
  ## monotonic throughout.
  if bd == 8:
    if fullRange:
      let c = y
      let d = cb - 128
      let e = cr - 128
      var r = jxsFDivPow2(256 * c + 403 * e + 128, 8)
      var g = jxsFDivPow2(256 * c - 48 * d - 120 * e + 128, 8)
      var b = jxsFDivPow2(256 * c + 475 * d + 128, 8)
      if r < 0: r = 0 elif r > 255: r = 255
      if g < 0: g = 0 elif g > 255: g = 255
      if b < 0: b = 0 elif b > 255: b = 255
      return (r, g, b)
    let c = y - 16
    let d = cb - 128
    let e = cr - 128
    var r = jxsFDivPow2(298 * c + 403 * e + 128, 8)
    var g = jxsFDivPow2(298 * c - 48 * d - 120 * e + 128, 8)
    var b = jxsFDivPow2(298 * c + 475 * d + 128, 8)
    if r < 0: r = 0 elif r > 255: r = 255
    if g < 0: g = 0 elif g > 255: g = 255
    if b < 0: b = 0 elif b > 255: b = 255
    return (r, g, b)
  let sh = bd.int - 8
  let s = 1 shl sh
  var c8 = 0
  var d8 = 0
  var e8 = 0
  if fullRange:
    c8 = jxsFDivPow2(y, sh)
    d8 = jxsFDivPow2(cb - 128 * s, sh)
    e8 = jxsFDivPow2(cr - 128 * s, sh)
    let (r8, g8, b8) = jxsYcbcrPixel(c8, d8 + 128, e8 + 128, 8, true)
    return (r8 * 257, g8 * 257, b8 * 257)
  c8 = jxsFDivPow2(y - 16 * s, sh)
  d8 = jxsFDivPow2(cb - 128 * s, sh)
  e8 = jxsFDivPow2(cr - 128 * s, sh)
  let (r8, g8, b8) = jxsYcbcrPixel(c8 + 16, d8 + 128, e8 + 128, 8)
  (r8 * 257, g8 * 257, b8 * 257)

func jxsLog2Sy*(sy: uint8): int =
  case sy
  of 1: 0
  of 2: 1
  of 4: 2
  else: -1

proc jxsGatherPrecinct*(prec: JxsPrecinctPlan, plan: JxsPicturePlan,
    h: JxsHeaders, deq: seq[seq[int]],
    gathered: var seq[seq[seq[int]]],
    samples: var seq[seq[int]]): ImageResult[bool] =
  ## Copy one precinct's dequantized bands into picture-level buffers.
  ## Suppressed (Sd) tail bands bypass the DWT: raw samples go straight
  ## into the component plane at the precinct's row offset.
  let px = (prec.p mod plan.npX).int
  let py = (prec.p div plan.npX).int
  let nDec = plan.nDecomposed
  for i in 0..<nDec.int:
    let sxI = plan.sx[i]
    let syI = plan.sy[i]
    let lg = jxsLog2Sy(syI)
    if lg < 0:
      return err[bool](decodingError("jxs: bad sampling factor"))
    let nlyI = satSub8(plan.nly, lg.uint8)
    let wcI = divCeil32(plan.wf, sxI.uint32).int
    let hcI = divCeil32(plan.hf, syI.uint32).int
    for betaPic in 0..<plan.nBeta.int:
      let b = (nDec * betaPic.uint32 + i.uint32).int
      let bg = prec.bands[b]
      if not bg.exists: continue
      let loc = prec.bandLocalBeta[b]
      if loc == high(uint32): continue
      let lines = (bg.l1 - bg.l0).int
      if lines <= 0: continue
      let (dxL, dyL, txL, tyL) = jxsBetaLevels(loc, plan.nlx, nlyI)
      let (picBW, picBH) = jxsBandDims(wcI, hcI, dxL, dyL, txL, tyL)
      let colsU =
        if not txL: divCeil32(plan.cs, (sxI.uint32 shl dxL).uint32).int
        else:
          let dm: uint32 =
            if dxL == 0: sxI.uint32
            else: sxI.uint32 shl (dxL - 1)
          divCeil32(plan.cs, dm).int div 2
      let colOff = px * colsU
      let powH =
        if nlyI == 0 or dyL >= nlyI: 1
        else: 1 shl (nlyI - dyL).int
      let rowOff = py * powH
      if gathered[i][loc.int].len != picBW * picBH:
        return err[bool](decodingError("jxs: gather buffer mismatch"))
      let wpb = bg.wpb.int
      for line in 0..<lines:
        let pr = rowOff + line
        if pr >= picBH: break
        let cw = min(wpb, picBW - colOff)
        if cw <= 0: break
        for x in 0..<cw:
          gathered[i][loc.int][pr * picBW + colOff + x] =
            deq[b][line * wpb + x]
  # Sd tail: raw-coded trailing components (sx=sy=1 enforced upstream).
  let sdU = plan.nc - nDec
  if sdU > 0:
    let wfI = plan.wf.int
    let hfI = plan.hf.int
    let csI = plan.cs.int
    let colOff = min(px * csI, wfI)
    let wp = min(wfI - colOff, prec.wp.int)
    let powPic = if plan.nly == 0: 1 else: 1 shl plan.nly.int
    let picRowOff = py * powPic
    for k in 0..<sdU.int:
      let i = (nDec + k.uint32).int
      let b = (nDec * plan.nBeta + k.uint32).int
      if b >= prec.bands.len or b >= deq.len: continue
      let bg = prec.bands[b]
      if not bg.exists: continue
      let lines = (bg.l1 - bg.l0).int
      if lines <= 0: continue
      let wpb = bg.wpb.int
      for line in 0..<lines:
        let pr = picRowOff + line
        if pr >= hfI: break
        let cw = min(min(wpb, wp), wfI - colOff)
        if cw <= 0: break
        for x in 0..<cw:
          samples[i][pr * wfI + colOff + x] = deq[b][line * wpb + x]
  ok(true)

proc jxsDecodeSlice*(sliceData: openArray[uint8], sPlan: JxsSlicePlan,
    plan: JxsPicturePlan, h: JxsHeaders,
    gathered: var seq[seq[seq[int]]],
    samples: var seq[seq[int]]): ImageResult[bool] =
  ## Decode one slice's precincts; accumulate into `gathered`/`samples`.
  let buf = @sliceData
  var cursor = 0
  let npX = plan.npX.int
  var colTops = newSeq[Option[JxsPrecinctTop]](max(npX, 1))
  let shortH = jxsUseShortHeader(h.pih)
  let ng = h.pih.ng
  let ss = h.pih.ss
  let br = h.pih.br
  let fs = h.pih.fs
  let rm = h.pih.rm
  let nBands = plan.nBands.int
  for prec in sPlan.precincts:
    let px = (prec.p mod plan.npX).int
    if cursor >= buf.len:
      return err[bool](decodingError("jxs: precinct past slice end"))
    let phR = jxsParsePrecinctHdr(buf.toOpenArray(cursor, buf.len - 1),
      prec)
    if not phR.ok: return err[bool](phR.err)
    let ph = phR.value
    let estart = cursor + ph.headerBytes
    let eend = estart + ph.lprc.int
    if eend > buf.len:
      return err[bool](decodingError("jxs: precinct overruns slice"))
    let trunc = jxsTruncTable(ph.q, ph.r, prec.bands)
    var state = jxsInitState(prec.bands, ng)
    var ecursor = estart
    var sumHdr = 0
    var sumCnt = 0
    var sumDat = 0
    var sumSgn = 0
    var sumSig = 0
    var firstDr = newSeq[int](nBands)
    for i in 0..<nBands: firstDr[i] = -1
    for layout in prec.packets:
      if layout.len == 0: continue
      if ecursor + 5 > eend:
        return err[bool](decodingError("jxs: packet past precinct end"))
      let pktR = jxsParsePacketHdr(buf.toOpenArray(ecursor, eend - 1),
        shortH)
      if not pktR.ok: return err[bool](pktR.err)
      let pkt = pktR.value
      ecursor += pkt.headerBytes
      let bodyR = jxsDecodePacketBody(
        buf.toOpenArray(ecursor, eend - 1), prec.bands, ng, ss, br,
        fs, rm, trunc, ph.d, pkt, layout, state, colTops[px])
      if not bodyR.ok: return err[bool](bodyR.err)
      ecursor += bodyR.value.consumed
      # Table C.1/C.3 cross-check: inferred Lsig must match bytes read.
      var sigBits = 0
      for e in layout:
        let bi = e.band.int
        if pkt.dr == 0 and (ph.d[bi] and 2) != 0:
          sigBits += jxsNs(prec.bands[bi].wpb, ng, ss).int
      if (sigBits + 7) div 8 != bodyR.value.sigBytes:
        return err[bool](decodingError("jxs: sig length mismatch"))
      if h.pih.rl == 0:
        for e in layout:
          let bi = e.band.int
          if firstDr[bi] < 0: firstDr[bi] = pkt.dr.int
          elif firstDr[bi] != pkt.dr.int:
            return err[bool](decodingError("jxs: Rl=0 raw mix"))
      sumHdr += pkt.headerBytes
      sumSig += bodyR.value.sigBytes
      sumCnt += pkt.lcnt.int
      sumDat += pkt.ldat.int
      if fs == 1: sumSgn += pkt.lsgn.int
    # Table C.1: Lprc must cover headers + sub-packets; rest is filler.
    # (Lcnt/Ldat/Lsgn act as sub-packet bounds during the read, so a
    # doctored-but-summing field only shifts filler, never samples.)
    if sumHdr + sumSig + sumCnt + sumDat + sumSgn > ph.lprc.int:
      return err[bool](decodingError("jxs: Lprc too small for packets"))
    colTops[px] = some(jxsCaptureTop(prec.bands, ng, trunc, state))
    let deq = jxsDequantPrecinct(h.pih.qpih, prec.bands, ng, trunc,
      state.coefs, h.pih.fq)
    let gR = jxsGatherPrecinct(prec, plan, h, deq, gathered, samples)
    if not gR.ok: return err[bool](gR.err)
    cursor = eend
  ok(true)

proc jxsDecodePicture*(cs: openArray[uint8], h: JxsHeaders,
    plan: JxsPicturePlan): ImageResult[seq[seq[int]]] =
  ## Supported matrix: uniform depth, Cpih 0/1 (YCbCr 444/422/420 or
  ## RCT), 1-4 comps, NLT quad/extended output, no CWD/Star-Tetrix.
  ## Returns post-colour-transform sample planes (row-major ints).
  if h.pih.cpih == 3:
    return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
      "jxs: Star-Tetrix transform"))
  if plan.sd > 0 and h.pih.cpih == 1 and
      (h.pih.nc.int - plan.sd.int) < 3:
    return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
      "jxs: RCT needs Nc-Sd >= 3"))
  if h.pih.cpih != 0 and h.pih.cpih != 1:
    return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
      "jxs: colour transform"))
  let b0 = h.comps[0].bitDepth
  for c in h.comps:
    if c.bitDepth != b0:
      return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
        "jxs: mixed bit depths"))
  if h.pih.bw < b0:
    return err[seq[seq[int]]](decodingError("jxs: Bw below B[i]"))
  if h.pih.cpih == 1 and h.comps.len < 3:
    return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
      "jxs: RCT needs Nc >= 3"))
  if h.pih.cpih == 1:
    for i in 0..<min(3, h.comps.len):
      if h.comps[i].sx != 1 or h.comps[i].sy != 1:
        return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
          "jxs: RCT with subsampled component"))
  if h.pih.cpih == 0 and h.comps.len == 1:
    if h.comps[0].sx != 1 or h.comps[0].sy != 1:
      return err[seq[seq[int]]](unsupportedError(ukGenericFeature,
        "jxs: subsampled luma"))
  if uint64(h.pih.wf) * uint64(h.pih.hf) > (1'u64 shl 28):
    return err[seq[seq[int]]](limitError(lkDimensionError,
      "jxs: picture exceeds 268 Mpixel"))
  if h.slices.len != plan.slices.len:
    return err[seq[seq[int]]](decodingError("jxs: slice count mismatch"))
  let nc = h.comps.len
  let wf = h.pih.wf.int
  let hf = h.pih.hf.int
  # per-component band buffers (local-β indexing per N'L,y[i])
  var gathered = newSeq[seq[seq[int]]](nc)
  for i in 0..<nc:
    let lg = jxsLog2Sy(h.comps[i].sy)
    if lg < 0:
      return err[seq[seq[int]]](decodingError("jxs: bad sampling factor"))
    let nlyIc = satSub8(h.pih.nly, lg.uint8)
    let wcI = (wf + h.comps[i].sx.int - 1) div h.comps[i].sx.int
    let hcI = (hf + h.comps[i].sy.int - 1) div h.comps[i].sy.int
    let nb = jxsNBeta(h.pih.nlx, nlyIc).int
    var bufs = newSeq[seq[int]](nb)
    for b in 0..<nb:
      let (dxL, dyL, txL, tyL) = jxsBetaLevels(b.uint32, h.pih.nlx,
        nlyIc)
      let (bwB, bhB) = jxsBandDims(wcI, hcI, dxL, dyL, txL, tyL)
      bufs[b] = newSeq[int](bwB * bhB)
    gathered[i] = move(bufs)
  var samples = newSeq[seq[int]](nc)
  for i in 0..<nc:
    let lg0 = jxsLog2Sy(h.comps[i].sy)
    let wc0 = (wf + h.comps[i].sx.int - 1) div h.comps[i].sx.int
    let hc0 = (hf + h.comps[i].sy.int - 1) div h.comps[i].sy.int
    samples[i] = newSeq[int](wc0 * hc0)
  for si, sp in plan.slices:
    let sl = h.slices[si]
    let r = jxsDecodeSlice(cs.toOpenArray(sl.dataOff,
      sl.dataOff + sl.dataLen - 1), sp, plan, h, gathered, samples)
    if not r.ok: return err[seq[seq[int]]](r.err)
  for i in 0..<nc:
    if i >= plan.nDecomposed.int: continue # Sd: already raw samples
    let lg = jxsLog2Sy(h.comps[i].sy)
    let nlyI = satSub8(h.pih.nly, lg.uint8)
    let wcI = (wf + h.comps[i].sx.int - 1) div h.comps[i].sx.int
    let hcI = (hf + h.comps[i].sy.int - 1) div h.comps[i].sy.int
    var outP = newSeq[int](wcI * hcI)
    let r = jxsInverseCascade(wcI, hcI, h.pih.nlx, nlyI, gathered[i],
      outP)
    if not r.ok: return err[seq[seq[int]]](r.err)
    samples[i] = move(outP)
  const guard = 1 shl 26
  for i in 0..<nc:
    for x in 0..<samples[i].len:
      if samples[i][x] < -guard: samples[i][x] = -guard
      elif samples[i][x] > guard: samples[i][x] = guard
  if h.pih.cpih == 1:
    var refs = samples
    jxsInverseRct(refs)
    samples = move(refs)
  ok(samples)


proc headersInfo(h: JxsHeaders, boxed: bool): JxsInfo =
  var mx: uint8 = 0
  for c in h.comps:
    if c.bitDepth > mx: mx = c.bitDepth
  JxsInfo(width: uint32(h.pih.wf), height: uint32(h.pih.hf),
    numComps: h.comps.len, bitDepth: mx, cpih: h.pih.cpih,
    lossless: h.pih.fq == 0, boxed: boxed, profile: h.pih.ppih,
    level: h.pih.plev)

proc jxsCheckFileMeta*(m: JxsFileMeta, h: JxsHeaders): ImageResult[bool] =
  ## A.5.4.2: a contradictory `.jxs` header fails the file.
  if m.ihdrW != h.pih.wf.uint32 or m.ihdrH != h.pih.hf.uint32 or
      m.ihdrNc != h.comps.len:
    return err[bool](decodingError("jxs: ihdr contradicts codestream"))
  if m.ihdrBd >= 0:
    for c in h.comps:
      if c.bitDepth.int != m.ihdrBd:
        return err[bool](decodingError("jxs: ihdr depth contradicts CDT"))
  ok(true)

proc jxsInfo*(data: openArray[uint8]): ImageResult[JxsInfo] =
  ## Header-only summary. Accepts a bare codestream or a `.jxs` file.
  ## A contradictory `.jxs` header (ihdr vs PIH) fails, like decode.
  if isJxsFile(data):
    let mR = parseJxsFile(data)
    if not mR.ok: return err[JxsInfo](mR.err)
    let h = parseJxsCodestream(data.toOpenArray(mR.value.csOff,
      mR.value.csOff + mR.value.csLen - 1))
    if not h.ok: return err[JxsInfo](h.err)
    let vR = jxsCheckFileMeta(mR.value, h.value)
    if not vR.ok: return err[JxsInfo](vR.err)
    return ok(headersInfo(h.value, true))
  let h = parseJxsCodestream(data)
  if not h.ok: return err[JxsInfo](h.err)
  ok(headersInfo(h.value, false))

proc decodeJxsRawEx*(data: openArray[uint8], matrix = -1,
    fullRange = false): ImageResult[DynamicImage] =
  ## Bare-codestream decode with optional Part-3 CICP override
  ## (`matrix` = H.273 code point, -1 = none; `fullRange` from V).
  ## Gray + RCT RGB(A) stills at 8..16 bits, YCbCr 444/422/420 (→RGB
  ## via BT.709 studio swing, or full swing under a CICP full flag;
  ## CICP matrix 0 at 4:4:4 decodes as RGB directly).
  let h0 = parseJxsCodestream(data)
  if not h0.ok: return err[DynamicImage](h0.err)
  var h = h0.value
  let sd: uint8 = if h.cwdSd < 0: 0 else: h.cwdSd.uint8
  let planR = jxsBuildPlan(h.pih, h.comps, h.wgt, sd)
  if not planR.ok: return err[DynamicImage](planR.err)
  let picR = jxsDecodePicture(data, h, planR.value)
  if not picR.ok: return err[DynamicImage](picR.err)
  let planes = picR.value
  let nc = h.comps.len
  let w = h.pih.wf.uint32
  let hh = h.pih.hf.uint32
  let bd = h.comps[0].bitDepth
  var rawPlanes: seq[seq[uint8]] = @[]
  var compW = newSeq[int](nc)
  var compH = newSeq[int](nc)
  for i in 0..<nc:
    if h.nltKind == 0:
      let loR = jxsLinearOut(planes[i], h.pih.bw, h.comps[i].bitDepth)
      if not loR.ok: return err[DynamicImage](loR.err)
      rawPlanes.add(loR.value)
    else:
      let nlt = if h.nltKind == 1: JxsNlt(kind: 1, dco: h.nltDco)
        else: JxsNlt(kind: 2, t1: h.nltT1, t2: h.nltT2, e: h.nltE)
      let noR = jxsNltOut(planes[i], h.pih.bw, h.comps[i].bitDepth, nlt)
      if not noR.ok: return err[DynamicImage](noR.err)
      rawPlanes.add(noR.value)
    compW[i] = (w.int + h.comps[i].sx.int - 1) div h.comps[i].sx.int
    compH[i] = (hh.int + h.comps[i].sy.int - 1) div h.comps[i].sy.int
  proc sampAt(p: seq[uint8], b: uint8, i: int): int =
    if b == 8: p[i].int
    else: (uint16(p[2*i]) or (uint16(p[2*i+1]) shl 8)).int
  if nc == 1 and bd == 8:
    if compW[0] != w.int or compH[0] != hh.int:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: subsampled luma"))
    var px = newSeq[Luma[uint8]](w.int * hh.int)
    for i in 0..<px.len: px[i] = Luma[uint8](data: [rawPlanes[0][i]])
    return ok(DynamicImage(kind: dkLuma8,
      luma8: GrayImage(width: w, height: hh, pixels: move(px))))
  if nc == 1 and bd > 8:
    if compW[0] != w.int or compH[0] != hh.int:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: subsampled luma"))
    var px = newSeq[Luma[uint16]](w.int * hh.int)
    for i in 0..<px.len:
      px[i] = Luma[uint16](data: [
        uint16(rawPlanes[0][2*i]) or (uint16(rawPlanes[0][2*i+1]) shl 8)])
    return ok(DynamicImage(kind: dkLuma16,
      luma16: Gray16Image(width: w, height: hh, pixels: move(px))))
  if h.pih.cpih == 1 and bd == 8 and (nc == 3 or nc == 4):
    for i in 0..<nc:
      if compW[i] != w.int or compH[i] != hh.int:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jxs: subsampled RCT plane"))
    if nc == 3:
      var px = newSeq[Rgb[uint8]](w.int * hh.int)
      for i in 0..<px.len:
        px[i] = Rgb[uint8](data: [rawPlanes[0][i], rawPlanes[1][i],
          rawPlanes[2][i]])
      return ok(DynamicImage(kind: dkRgb8,
        rgb8: RgbImage(width: w, height: hh, pixels: move(px))))
    var px = newSeq[Rgba[uint8]](w.int * hh.int)
    for i in 0..<px.len:
      px[i] = Rgba[uint8](data: [rawPlanes[0][i], rawPlanes[1][i],
        rawPlanes[2][i], rawPlanes[3][i]])
    return ok(DynamicImage(kind: dkRgba8,
      rgba8: RgbaImage(width: w, height: hh, pixels: move(px))))
  if h.pih.cpih == 1 and bd > 8 and (nc == 3 or nc == 4):
    for i in 0..<nc:
      if compW[i] != w.int or compH[i] != hh.int:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jxs: subsampled RCT plane"))
    proc u16At(p: seq[uint8], i: int): uint16 =
      uint16(p[2*i]) or (uint16(p[2*i+1]) shl 8)
    if nc == 3:
      var px = newSeq[Rgb[uint16]](w.int * hh.int)
      for i in 0..<px.len:
        px[i] = Rgb[uint16](data: [u16At(rawPlanes[0], i),
          u16At(rawPlanes[1], i), u16At(rawPlanes[2], i)])
      return ok(DynamicImage(kind: dkRgb16,
        rgb16: Rgb16Image(width: w, height: hh, pixels: move(px))))
    var px = newSeq[Rgba[uint16]](w.int * hh.int)
    for i in 0..<px.len:
      px[i] = Rgba[uint16](data: [u16At(rawPlanes[0], i),
        u16At(rawPlanes[1], i), u16At(rawPlanes[2], i),
        u16At(rawPlanes[3], i)])
    return ok(DynamicImage(kind: dkRgba16,
      rgba16: Rgba16Image(width: w, height: hh, pixels: move(px))))
  if h.pih.cpih == 0 and (nc == 3 or nc == 4):
    # YCbCr 444/422/420 (+ optional full-res alpha) → RGB(A).
    # CICP matrix 0 at 4:4:4 means identity (RGB directly, no math);
    # anything else decodes as YCbCr via BT.709 (limited studio swing
    # by default, full swing under a CICP V flag).
    let effM = if matrix in [0, 1]: matrix else: 1
    let fr = fullRange and matrix >= 0
    if compW[0] != w.int or compH[0] != hh.int:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: subsampled luma"))
    let sxC = h.comps[1].sx.int
    let syC = h.comps[1].sy.int
    if h.comps[2].sx.int != sxC or h.comps[2].sy.int != syC:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: luma/chroma sampling"))
    if (sxC notin [1, 2]) or (syC notin [1, 2]) or
        (sxC == 1 and syC == 2):
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: chroma sampling"))
    if nc == 4 and (compW[3] != w.int or compH[3] != hh.int):
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jxs: subsampled alpha"))
    let cwC = compW[1]
    let chC = compH[1]
    if effM == 0:
      # Identity: planes already hold RGB(A); requires 4:4:4.
      if sxC != 1 or syC != 1:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jxs: CICP identity needs 4:4:4"))
      if bd == 8 and nc == 3:
        var px = newSeq[Rgb[uint8]](w.int * hh.int)
        for i in 0..<px.len:
          px[i] = Rgb[uint8](data: [rawPlanes[0][i], rawPlanes[1][i],
            rawPlanes[2][i]])
        return ok(DynamicImage(kind: dkRgb8,
          rgb8: RgbImage(width: w, height: hh, pixels: move(px))))
      if bd == 8:
        var px = newSeq[Rgba[uint8]](w.int * hh.int)
        for i in 0..<px.len:
          px[i] = Rgba[uint8](data: [rawPlanes[0][i], rawPlanes[1][i],
            rawPlanes[2][i], rawPlanes[3][i]])
        return ok(DynamicImage(kind: dkRgba8,
          rgba8: RgbaImage(width: w, height: hh, pixels: move(px))))
      proc u16Id(p: seq[uint8], i: int): uint16 =
        uint16(p[2*i]) or (uint16(p[2*i+1]) shl 8)
      if nc == 3:
        var px = newSeq[Rgb[uint16]](w.int * hh.int)
        for i in 0..<px.len:
          px[i] = Rgb[uint16](data: [u16Id(rawPlanes[0], i),
            u16Id(rawPlanes[1], i), u16Id(rawPlanes[2], i)])
        return ok(DynamicImage(kind: dkRgb16,
          rgb16: Rgb16Image(width: w, height: hh, pixels: move(px))))
      var px = newSeq[Rgba[uint16]](w.int * hh.int)
      for i in 0..<px.len:
        px[i] = Rgba[uint16](data: [u16Id(rawPlanes[0], i),
          u16Id(rawPlanes[1], i), u16Id(rawPlanes[2], i),
          u16Id(rawPlanes[3], i)])
      return ok(DynamicImage(kind: dkRgba16,
        rgba16: Rgba16Image(width: w, height: hh, pixels: move(px))))
    if bd == 8:
      if nc == 3:
        var px = newSeq[Rgb[uint8]](w.int * hh.int)
        for y in 0..<hh.int:
          for x in 0..<w.int:
            let cx = min(x div sxC, cwC - 1)
            let cy = min(y div syC, chC - 1)
            let (r, g, b) = jxsYcbcrPixel(rawPlanes[0][y*w.int+x].int,
              rawPlanes[1][cy*cwC+cx].int, rawPlanes[2][cy*cwC+cx].int, 8, fr)
            px[y*w.int+x] = Rgb[uint8](data: [r.uint8, g.uint8, b.uint8])
        return ok(DynamicImage(kind: dkRgb8,
          rgb8: RgbImage(width: w, height: hh, pixels: move(px))))
      var px = newSeq[Rgba[uint8]](w.int * hh.int)
      for y in 0..<hh.int:
        for x in 0..<w.int:
          let cx = min(x div sxC, cwC - 1)
          let cy = min(y div syC, chC - 1)
          let (r, g, b) = jxsYcbcrPixel(rawPlanes[0][y*w.int+x].int,
            rawPlanes[1][cy*cwC+cx].int, rawPlanes[2][cy*cwC+cx].int, 8, fr)
          px[y*w.int+x] = Rgba[uint8](data: [r.uint8, g.uint8, b.uint8,
            rawPlanes[3][y*w.int+x]])
      return ok(DynamicImage(kind: dkRgba8,
        rgba8: RgbaImage(width: w, height: hh, pixels: move(px))))
    # 9..16-bit: same conversion in the low `bd` bits.
    if nc == 3:
      var px = newSeq[Rgb[uint16]](w.int * hh.int)
      for y in 0..<hh.int:
        for x in 0..<w.int:
          let cx = min(x div sxC, cwC - 1)
          let cy = min(y div syC, chC - 1)
          let (r, g, b) = jxsYcbcrPixel(sampAt(rawPlanes[0], bd, y*w.int+x),
            sampAt(rawPlanes[1], bd, cy*cwC+cx),
            sampAt(rawPlanes[2], bd, cy*cwC+cx), bd, fr)
          px[y*w.int+x] = Rgb[uint16](data: [r.uint16, g.uint16, b.uint16])
      return ok(DynamicImage(kind: dkRgb16,
        rgb16: Rgb16Image(width: w, height: hh, pixels: move(px))))
    var px = newSeq[Rgba[uint16]](w.int * hh.int)
    for y in 0..<hh.int:
      for x in 0..<w.int:
        let cx = min(x div sxC, cwC - 1)
        let cy = min(y div syC, chC - 1)
        let (r, g, b) = jxsYcbcrPixel(sampAt(rawPlanes[0], bd, y*w.int+x),
          sampAt(rawPlanes[1], bd, cy*cwC+cx),
          sampAt(rawPlanes[2], bd, cy*cwC+cx), bd, fr)
        px[y*w.int+x] = Rgba[uint16](data: [r.uint16, g.uint16, b.uint16,
          sampAt(rawPlanes[3], bd, y*w.int+x).uint16])
    return ok(DynamicImage(kind: dkRgba16,
      rgba16: Rgba16Image(width: w, height: hh, pixels: move(px))))
  err[DynamicImage](unsupportedError(ukGenericFeature,
    "jxs: DynamicImage mapping for this layout"))

proc decodeJxsRaw*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## Bare-codestream decode (no Part-3 colour override).
  decodeJxsRawEx(data)

proc decodeJxs*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## Bare codestream or `.jxs` file decode. A contradictory `.jxs`
  ## header fails; CICP matrix/full-range steer the YCbCr→RGB output.
  if isJxsFile(data):
    let mR = parseJxsFile(data)
    if not mR.ok: return err[DynamicImage](mR.err)
    let m = mR.value
    let h0 = parseJxsCodestream(data.toOpenArray(m.csOff,
      m.csOff + m.csLen - 1))
    if not h0.ok: return err[DynamicImage](h0.err)
    let vR = jxsCheckFileMeta(m, h0.value)
    if not vR.ok: return err[DynamicImage](vR.err)
    return decodeJxsRawEx(data.toOpenArray(m.csOff,
      m.csOff + m.csLen - 1), m.matrix, m.fullRange)
  decodeJxsRaw(data)
