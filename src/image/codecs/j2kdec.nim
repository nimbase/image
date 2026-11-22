## JPEG 2000 decoder (pure Nim, clean-room port).
## Technical reference: microsoft/jpeg2000_rs (MIT, (c) Microsoft Corporation)
## src/codestream/* (markers/layout/quantization/tiles), src/packet/*,
## src/tier1/*, src/transform/*, src/jp2/*. No standards text or test
## vectors are reproduced; only coding semantics re-expressed.
## HT VLC tables (when added) derive from OpenJPEG t1_ht_luts.h and retain
## their BSD-2 notices (see references THIRD_PARTY_NOTICES) alongside MIT.
## Scope v1: raw codestream (.j2k: SOC..EOC, single/multi tile, POC) + JP2
## container (.jp2: signature/ftyp/jp2h/jp2c first-codestream) stills to
## DynamicImage. Lossless 5/3 + RCT first; 9/7 + HT follow in later phases.
## Out of v1 scope (clean Unsupported): JPX/JPH/JPIP, Part-2 general MCT/
## MCO/NLT/CBD/decomposition selectors, HT/mixed routing (phase-gated),
## palette execution beyond gray/RGB/RGBA mapping, animation, encode.
import ../error
import ../buffer
import ../dynamic
import ../color
import ../limits

# ---------- markers ----------

const
  MkSoc* = 0xFF4Fu16
  MkSiz* = 0xFF51u16
  MkCod* = 0xFF52u16
  MkCoc* = 0xFF53u16
  MkQcd* = 0xFF5Cu16
  MkQcc* = 0xFF5Du16
  MkRgn* = 0xFF5Eu16
  MkPoc* = 0xFF5Fu16
  MkPpm* = 0xFF60u16
  MkPpt* = 0xFF61u16
  MkCrg* = 0xFF63u16
  MkCom* = 0xFF64u16
  MkSot* = 0xFF90u16
  MkSop* = 0xFF91u16
  MkEph* = 0xFF92u16
  MkSod* = 0xFF93u16
  MkEoc* = 0xFFD9u16
  MkTlm* = 0xFF55u16
  MkPlm* = 0xFF57u16
  MkPlt* = 0xFF58u16

type
  J2kProg* = enum
    prLrcp, prRlcp, prRpcl, prPcrl, prCprl

  J2kCompInfo* = object
    prec*: int       # nominal precision 1..38
    signed*: bool
    xr*, yr*: int    # subsampling, nonzero

  J2kSiz* = object
    rsiz*: uint16
    xsiz*, ysiz*: uint32
    xosiz*, yosiz*: uint32
    xtsiz*, ytsiz*: uint32
    xtosiz*, ytosiz*: uint32
    comps*: seq[J2kCompInfo]

  J2kCodingStyle* = object
    precincts*: bool
    sop*: bool
    eph*: bool
    prog*: J2kProg
    layers*: int
    mct*: bool
    dlevels*: int
    xcb*, ycb*: int   # exponents; block W = 1 shl (xcb+2)
    selBypass*: bool  # coding style byte bit 0 (bypass/bypass-like)
    reset*: bool
    termAll*: bool
    vcausal*: bool
    predictable*: bool
    segSym*: bool
    ht*: bool         # HT code-block style (style >> 6 == 1)
    mixed*: bool      # mixed legacy/HT (style >> 6 == 3)
    trans*: int       # 0 = irreversible 9/7, 1 = reversible 5/3
    ppx*, ppy*: seq[int]  # precinct exponents per resolution, if any

  J2kQStep* = object
    exp*: int
    mant*: int

  J2kQuant* = object
    style*: int       # 0 none, 1 derived, 2 expounded
    guard*: int
    steps*: seq[J2kQStep]

  J2kTilePart* = object
    isot*: int
    psot*: uint32
    tpsot*: int
    tnsot*: int
    hdrStart*: int    # offset of SOT marker
    dataStart*: int   # offset just past SOD
    dataEnd*: int     # exclusive
    pocPay*: seq[seq[uint8]]  # POC segments from tile-part headers
    hasPpt*: bool     # packed packet headers (follow-up)
    hasCodingOverride*: bool  # tile COD/COC/QCD/QCC/RGN (follow-up)

  J2kHeaders* = object
    siz*: J2kSiz
    cod*: J2kCodingStyle
    hasCod*: bool
    qcd*: J2kQuant
    hasQcd*: bool
    cocs*: seq[tuple[comp: int, st: J2kCodingStyle]]
    qccs*: seq[tuple[comp: int, q: J2kQuant]]
    rgn*: seq[tuple[comp: int, shift: int]]
    poc*: seq[tuple[rS, cS, lE, rE, cE: int, pr: J2kProg]]
    ppt*: seq[seq[uint8]]  # packed packet headers, main header (concatenated use later)
    ppm*: seq[uint8]
    tlm*: seq[tuple[itile, psot: int]]
    parts*: seq[J2kTilePart]

func u16be(d: openArray[uint8], off: int): uint16 =
  (uint16(d[off]) shl 8) or uint16(d[off+1])

func u32be(d: openArray[uint8], off: int): uint32 =
  (uint32(d[off]) shl 24) or (uint32(d[off+1]) shl 16) or
    (uint32(d[off+2]) shl 8) or uint32(d[off+3])

func ceilDiv(a, b: int): int =
  (a + b - 1) div b

proc tileGrid*(s: J2kSiz): tuple[nx, ny: int] =
  (ceilDiv(int(s.xsiz) - int(s.xtosiz), int(s.xtsiz)),
   ceilDiv(int(s.ysiz) - int(s.ytosiz), int(s.ytsiz)))

proc frameSize*(s: J2kSiz): tuple[w, h: int] =
  (int(s.xsiz) - int(s.xosiz), int(s.ysiz) - int(s.yosiz))

# ---------- marker segment walk ----------

type SegCursor = object
  pos: int
  marker: uint16
  payOff: int
  payLen: int

proc nextSeg(data: openArray[uint8], pos: var int, standaloneOk: bool,
    res: var SegCursor): bool =
  ## Read one marker at pos. Standalone (SOC/SOD/EOC/EPH/SOP-like in-data)
  ## consume 2 bytes; addressed segments consume marker + L + payload.
  ## Returns false on truncation / bad framing (caller maps to error).
  if pos + 2 > data.len: return false
  if data[pos] != 0xFF: return false
  let m = (uint16(data[pos]) shl 8) or uint16(data[pos+1])
  if m == MkSoc or m == MkSod or m == MkEoc or m == MkEph:
    res = SegCursor(pos: pos, marker: m, payOff: pos + 2, payLen: 0)
    pos += 2
    return true
  if not standaloneOk and (m == MkSop):
    return false
  if pos + 4 > data.len: return false
  let ln = int(u16be(data, pos + 2))
  if ln < 2: return false
  if pos + 2 + ln > data.len: return false
  res = SegCursor(pos: pos, marker: m, payOff: pos + 4, payLen: ln - 2)
  pos += 2 + ln
  true

# ---------- SIZ ----------

proc parseSiz(p: openArray[uint8]): ImageResult[J2kSiz] =
  if p.len < 36:
    return err[J2kSiz](decodingError("j2k: SIZ too short"))
  var s: J2kSiz
  s.rsiz = u16be(p, 0)
  s.xsiz = u32be(p, 2); s.ysiz = u32be(p, 6)
  s.xosiz = u32be(p, 10); s.yosiz = u32be(p, 14)
  s.xtsiz = u32be(p, 18); s.ytsiz = u32be(p, 22)
  s.xtosiz = u32be(p, 26); s.ytosiz = u32be(p, 30)
  let csiz = int(u16be(p, 34))
  if csiz <= 0 or csiz > 64:
    return err[J2kSiz](decodingError("j2k: bad Csiz"))
  if p.len != 36 + 3 * csiz:
    return err[J2kSiz](decodingError("j2k: bad SIZ length"))
  if not (s.xsiz > s.xosiz and s.ysiz > s.yosiz):
    return err[J2kSiz](decodingError("j2k: bad canvas origin"))
  if s.xtsiz == 0 or s.ytsiz == 0:
    return err[J2kSiz](decodingError("j2k: bad tile size"))
  if s.xtosiz > s.xosiz or s.ytosiz > s.yosiz:
    return err[J2kSiz](decodingError("j2k: bad tile origin"))
  if int(s.xtosiz) + int(s.xtsiz) <= int(s.xosiz): # must overlap canvas
    return err[J2kSiz](decodingError("j2k: tile off canvas"))
  if int(s.ytosiz) + int(s.ytsiz) <= int(s.yosiz):
    return err[J2kSiz](decodingError("j2k: tile off canvas"))
  s.comps = newSeq[J2kCompInfo](csiz)
  for i in 0..<csiz:
    let ss = p[36 + 3*i]; let xr = int(p[36+3*i+1]); let yr = int(p[36+3*i+2])
    if xr == 0 or yr == 0:
      return err[J2kSiz](decodingError("j2k: bad subsampling"))
    let prec = int(ss and 0x7F) + 1
    if prec < 1 or prec > 38:
      return err[J2kSiz](decodingError("j2k: bad precision"))
    s.comps[i] = J2kCompInfo(prec: prec, signed: (ss and 0x80) != 0,
      xr: xr, yr: yr)
  ok(s)

# ---------- COD / COC ----------

proc parseProg(v: int): tuple[ok: bool, pr: J2kProg] =
  case v
  of 0: (true, prLrcp)
  of 1: (true, prRlcp)
  of 2: (true, prRpcl)
  of 3: (true, prPcrl)
  of 4: (true, prCprl)
  else: (false, prLrcp)

proc parseCodBody(p: openArray[uint8], isCoc: bool): ImageResult[J2kCodingStyle] =
  if p.len < 10:
    return err[J2kCodingStyle](decodingError("j2k: COD too short"))
  var st: J2kCodingStyle
  let scod = p[0]
  if (scod and 0xF8) != 0:
    return err[J2kCodingStyle](decodingError("j2k: bad Scod"))
  st.precincts = (scod and 1) != 0
  st.sop = (scod and 2) != 0
  st.eph = (scod and 4) != 0
  let (pok, pr) = parseProg(int(p[1]))
  if not pok:
    return err[J2kCodingStyle](decodingError("j2k: bad progression"))
  st.prog = pr
  st.layers = (int(p[2]) shl 8) or int(p[3])
  if st.layers < 1 or st.layers > 65535:
    return err[J2kCodingStyle](decodingError("j2k: bad layers"))
  let mct = int(p[4])
  if mct != 0 and mct != 1:
    return err[J2kCodingStyle](decodingError("j2k: bad MCT flag"))
  st.mct = mct == 1
  st.dlevels = int(p[5])
  if st.dlevels < 0 or st.dlevels > 32:
    return err[J2kCodingStyle](decodingError("j2k: bad levels"))
  if int(p[6]) > 8 or int(p[7]) > 8:
    return err[J2kCodingStyle](decodingError("j2k: bad codeblock exp"))
  st.xcb = int(p[6]); st.ycb = int(p[7])
  if (1 shl (st.xcb + 2)) * (1 shl (st.ycb + 2)) > 4096:
    return err[J2kCodingStyle](decodingError("j2k: codeblock too large"))
  let sb = p[8]
  st.selBypass = (sb and 0x01) != 0
  st.reset = (sb and 0x02) != 0
  st.termAll = (sb and 0x04) != 0
  st.vcausal = (sb and 0x08) != 0
  st.predictable = (sb and 0x10) != 0
  st.segSym = (sb and 0x20) != 0
  let mode = sb shr 6
  st.ht = mode == 1
  st.mixed = mode == 3
  if mode == 2:
    return err[J2kCodingStyle](decodingError("j2k: bad codeblock style"))
  if st.ht and (sb and 0x37) != 0:
    return err[J2kCodingStyle](decodingError("j2k: bad HT style"))
  if st.mixed and (sb and 0x05) != 0:
    return err[J2kCodingStyle](decodingError("j2k: bad mixed style"))
  let tr = int(p[9])
  if tr != 0 and tr != 1:
    # Part-2 arbitrary kernels deferred to a later phase.
    return err[J2kCodingStyle](unsupportedError(ukGenericFeature,
      "j2k: arbitrary wavelet kernel"))
  st.trans = tr
  let nres = st.dlevels + 1
  if st.precincts:
    if p.len != 10 + nres:
      return err[J2kCodingStyle](decodingError("j2k: bad precinct bytes"))
    st.ppx = newSeq[int](nres); st.ppy = newSeq[int](nres)
    for i in 0..<nres:
      st.ppx[i] = int(p[10+i] and 0x0F)
      st.ppy[i] = int(p[10+i] shr 4)
  else:
    if p.len != 10:
      return err[J2kCodingStyle](decodingError("j2k: bad COD length"))
  ok(st)

# ---------- QCD / QCC ----------

proc subbandCount(dlevels: int): int = 1 + 3 * dlevels

proc parseQcdBody(p: openArray[uint8], nsub: int): ImageResult[J2kQuant] =
  if p.len < 1:
    return err[J2kQuant](decodingError("j2k: QCD too short"))
  let sq = p[0]
  let guard = int(sq shr 5); let style = int(sq and 0x1F)
  if style != 0 and style != 1 and style != 2:
    return err[J2kQuant](decodingError("j2k: bad quantization style"))
  var q: J2kQuant
  q.style = style; q.guard = guard
  if style == 0:
    if p.len - 1 != nsub:
      return err[J2kQuant](decodingError("j2k: bad QCD/none length"))
    q.steps = newSeq[J2kQStep](nsub)
    for i in 0..<nsub:
      let b = p[1+i]
      if (b and 0x07) != 0:
        return err[J2kQuant](decodingError("j2k: bad QCD/none step"))
      q.steps[i] = J2kQStep(exp: int(b shr 3), mant: 0)
  elif style == 1:
    if p.len != 3:
      return err[J2kQuant](decodingError("j2k: bad QCD/derived length"))
    let w = (int(p[1]) shl 8) or int(p[2])
    q.steps = @[J2kQStep(exp: w shr 11, mant: w and 0x07FF)]
  else:
    if p.len - 1 != 2 * nsub:
      return err[J2kQuant](decodingError("j2k: bad QCD/expounded length"))
    q.steps = newSeq[J2kQStep](nsub)
    for i in 0..<nsub:
      let w = (int(p[1+2*i]) shl 8) or int(p[1+2*i+1])
      q.steps[i] = J2kQStep(exp: w shr 11, mant: w and 0x07FF)
  if q.steps.len > 97:
    return err[J2kQuant](decodingError("j2k: too many quant steps"))
  ok(q)

# ---------- main header ----------

proc compFieldLen(csiz: int): int =
  if csiz < 257: 1 else: 2

proc parsePocPayload(pay: openArray[uint8], ncomp: int): ImageResult[
    seq[tuple[rS, cS, lE, rE, cE: int, pr: J2kProg]]] =
  ## Parse POC records (main or tile-part header). Shared by both.
  let fl = compFieldLen(ncomp)
  # Record: RSpoc(1) + CSpoc(fl) + LYEpoc(2) + REpoc(1) + CEpoc(fl) +
  # Ppoc(1) = 5 + 2*fl bytes (ref coding_markers.rs:350+).
  let recl = 5 + 2 * fl
  var recs: seq[tuple[rS, cS, lE, rE, cE: int, pr: J2kProg]] = @[]
  if pay.len mod recl != 0 or pay.len == 0:
    return err[type(recs)](decodingError("j2k: bad POC length"))
  var off = 0
  while off < pay.len:
    var idx = off
    let rS = int(pay[idx]); idx += 1
    var cS: int
    if fl == 1:
      cS = int(pay[idx]); idx += 1
    else:
      cS = (int(pay[idx]) shl 8) or int(pay[idx+1]); idx += 2
    let lE = (int(pay[idx]) shl 8) or int(pay[idx+1]); idx += 2
    let rE = int(pay[idx]); idx += 1
    var cE: int
    if fl == 1:
      cE = int(pay[idx]); idx += 1
    else:
      cE = (int(pay[idx]) shl 8) or int(pay[idx+1]); idx += 2
    let (pok, pr) = parseProg(int(pay[idx])); idx += 1
    if not pok:
      return err[type(recs)](decodingError("j2k: bad POC progression"))
    if lE < 1 or lE > 65535 or cS >= cE or cE > ncomp or
        rS >= rE or rE > 33:
      return err[type(recs)](decodingError("j2k: bad POC record"))
    recs.add((rS: rS, cS: cS, lE: lE, rE: rE, cE: cE, pr: pr))
    off += recl
  ok(recs)

proc parseMainHeader(data: openArray[uint8], pos: var int,
    h: var J2kHeaders): ImageResult[bool] =
  ## Parses SIZ..first SOT (main header). pos starts just past SOC.
  var seenSiz = false
  var seg: SegCursor
  while true:
    if pos + 2 > data.len:
      return err[bool](decodingError("j2k: truncated main header"))
    if data[pos] != 0xFF:
      return err[bool](decodingError("j2k: bad marker in main header"))
    let m = u16be(data, pos)
    if m == MkSot or m == MkSod:
      break
    if m == MkEoc:
      return err[bool](decodingError("j2k: EOC in main header"))
    if m == MkSoc:
      return err[bool](decodingError("j2k: double SOC"))
    if not nextSeg(data, pos, false, seg):
      return err[bool](decodingError("j2k: truncated segment"))
    # NOTE: openArray cannot live in a let (Nim 2.4); copy the tiny header
    # payload into a seq (headers are bytes, packet bodies borrow later).
    if seg.payLen <= 0:
      return err[bool](decodingError("j2k: empty segment"))
    let pay = @(data.toOpenArray(seg.payOff, seg.payOff + seg.payLen - 1))
    case seg.marker
    of MkSiz:
      if seenSiz:
        return err[bool](decodingError("j2k: duplicate SIZ"))
      let r = parseSiz(pay)
      if not r.ok: return err[bool](r.err)
      h.siz = r.value; seenSiz = true
    of MkCod:
      if not seenSiz:
        return err[bool](decodingError("j2k: COD before SIZ"))
      if h.hasCod:
        return err[bool](decodingError("j2k: duplicate COD"))
      let r = parseCodBody(pay, false)
      if not r.ok: return err[bool](r.err)
      h.cod = r.value; h.hasCod = true
    of MkCoc:
      if not seenSiz:
        return err[bool](decodingError("j2k: COC before SIZ"))
      let fl = compFieldLen(h.siz.comps.len)
      if pay.len < fl + 10:
        return err[bool](decodingError("j2k: COC too short"))
      var comp = 0
      if fl == 1: comp = int(pay[0])
      else: comp = (int(pay[0]) shl 8) or int(pay[1])
      if comp < 0 or comp >= h.siz.comps.len:
        return err[bool](decodingError("j2k: COC bad component"))
      for e in h.cocs:
        if e.comp == comp:
          return err[bool](decodingError("j2k: duplicate COC"))
      let r = parseCodBody(pay.toOpenArray(fl + 1, pay.len - 1), true)
      if not r.ok: return err[bool](r.err)
      h.cocs.add((comp: comp, st: r.value))
    of MkQcd:
      if not seenSiz or not h.hasCod:
        return err[bool](decodingError("j2k: QCD order"))
      if h.hasQcd:
        return err[bool](decodingError("j2k: duplicate QCD"))
      let r = parseQcdBody(pay, subbandCount(h.cod.dlevels))
      if not r.ok: return err[bool](r.err)
      h.qcd = r.value; h.hasQcd = true
    of MkQcc:
      if not seenSiz or not h.hasCod:
        return err[bool](decodingError("j2k: QCC order"))
      let fl = compFieldLen(h.siz.comps.len)
      if pay.len < fl + 1:
        return err[bool](decodingError("j2k: QCC too short"))
      var comp = 0
      if fl == 1: comp = int(pay[0])
      else: comp = (int(pay[0]) shl 8) or int(pay[1])
      if comp < 0 or comp >= h.siz.comps.len:
        return err[bool](decodingError("j2k: QCC bad component"))
      var nsub = subbandCount(h.cod.dlevels)
      for e in h.cocs:
        if e.comp == comp: nsub = subbandCount(e.st.dlevels)
      let r = parseQcdBody(pay.toOpenArray(fl + 1, pay.len - 1), nsub)
      if not r.ok: return err[bool](r.err)
      h.qccs.add((comp: comp, q: r.value))
    of MkRgn:
      let fl = compFieldLen(h.siz.comps.len)
      if seg.payLen != fl + 2:
        return err[bool](decodingError("j2k: bad RGN length"))
      var comp = 0
      if fl == 1: comp = int(pay[0])
      else: comp = (int(pay[0]) shl 8) or int(pay[1])
      if comp < 0 or comp >= h.siz.comps.len:
        return err[bool](decodingError("j2k: RGN bad component"))
      if pay[pay.len - 2] != 0:
        return err[bool](unsupportedError(ukGenericFeature,
          "j2k: non-maxshift ROI"))
      h.rgn.add((comp: comp, shift: int(pay[pay.len - 1])))
    of MkPoc:
      let pr = parsePocPayload(pay, h.siz.comps.len)
      if not pr.ok: return err[bool](pr.err)
      h.poc.add(pr.value)
    of MkPpm:
      h.ppm.add(pay)
    of MkPpt:
      h.ppt.add(pay)
    of MkTlm, MkPlm, MkPlt, MkCrg, MkCom:
      discard # parsed-and-skipped in M1; enforced in packet phase
    else:
      return err[bool](unsupportedError(ukGenericFeature,
        "j2k: marker 0x" & $seg.marker))
  if not seenSiz or not h.hasCod or not h.hasQcd:
    return err[bool](decodingError("j2k: missing SIZ/COD/QCD"))
  ok(true)

# ---------- tile parts ----------

proc parseTileParts(data: openArray[uint8], pos: var int,
    h: var J2kHeaders): ImageResult[bool] =
  var tileCount = 0
  let g = tileGrid(h.siz)
  tileCount = g.nx * g.ny
  if tileCount <= 0:
    return err[bool](decodingError("j2k: bad tile grid"))
  var seenEoc = false
  while true:
    if pos + 2 > data.len:
      return err[bool](decodingError("j2k: truncated tile header"))
    if data[pos] != 0xFF:
      return err[bool](decodingError("j2k: bad tile marker"))
    let m = u16be(data, pos)
    if m == MkEoc:
      pos += 2
      seenEoc = true
      break
    if m != MkSot:
      return err[bool](decodingError("j2k: expected SOT"))
    var seg: SegCursor
    if not nextSeg(data, pos, false, seg):
      return err[bool](decodingError("j2k: truncated SOT"))
    if seg.marker != MkSot:
      return err[bool](decodingError("j2k: bad SOT"))
    if seg.payLen != 8:
      return err[bool](decodingError("j2k: bad SOT length"))
    let isot = (int(data[seg.payOff]) shl 8) or int(data[seg.payOff+1])
    let psot = u32be(data, seg.payOff + 2)
    let tpsot = int(data[seg.payOff+6]); let tnsot = int(data[seg.payOff+7])
    if isot < 0 or isot >= tileCount:
      return err[bool](decodingError("j2k: SOT bad tile index"))
    if tnsot != 0 and tpsot >= tnsot:
      return err[bool](decodingError("j2k: SOT bad part index"))
    if psot != 0 and psot < 14:
      return err[bool](decodingError("j2k: SOT bad Psot"))
    # tile-part header segments until SOD
    var inner: SegCursor
    var validSod = false
    var pocPay: seq[seq[uint8]] = @[]
    var hasPpt = false
    var hasCodingOverride = false
    while true:
      if pos + 2 > data.len:
        return err[bool](decodingError("j2k: truncated tile-part header"))
      let mm = u16be(data, pos)
      if mm == MkSod:
        pos += 2
        validSod = true
        break
      if mm == MkSot or mm == MkEoc:
        return err[bool](decodingError("j2k: SOD expected"))
      if not nextSeg(data, pos, false, inner):
        return err[bool](decodingError("j2k: truncated tile segment"))
      # Tile-part header overrides: POC is parsed per tile (opj places it
      # here); PPT and COD/COC/QCD/QCC/RGN overrides stay Unsupported.
      case inner.marker
      of MkPoc:
        if inner.payLen <= 0:
          return err[bool](decodingError("j2k: empty POC"))
        pocPay.add(@(data.toOpenArray(inner.payOff,
          inner.payOff + inner.payLen - 1)))
      of MkPpt:
        hasPpt = true
      of MkCod, MkCoc, MkQcd, MkQcc, MkRgn:
        hasCodingOverride = true
      of MkTlm, MkPlm, MkPlt, MkCrg, MkCom:
        discard
      else:
        return err[bool](unsupportedError(ukGenericFeature,
          "j2k: tile marker 0x" & $inner.marker))
    if not validSod:
      return err[bool](decodingError("j2k: missing SOD"))
    let dataStart = pos
    let sotOff = seg.pos
    var dataEnd = -1
    if psot == 0:
      # open-ended: scan to EOC
      var q = pos
      var found = false
      while q + 2 <= data.len:
        if data[q] == 0xFF and data[q+1] == 0xD9:
          dataEnd = q
          found = true
          break
        inc q
      if not found:
        return err[bool](decodingError("j2k: missing EOC"))
    else:
      dataEnd = sotOff + int(psot)
      if dataEnd < dataStart or dataEnd > data.len:
        return err[bool](decodingError("j2k: SOT Psot OOB"))
    h.parts.add(J2kTilePart(isot: isot, psot: psot, tpsot: tpsot,
      tnsot: tnsot, hdrStart: sotOff, dataStart: dataStart, dataEnd: dataEnd,
      pocPay: move(pocPay), hasPpt: hasPpt,
      hasCodingOverride: hasCodingOverride))
    pos = dataEnd
  if not seenEoc:
    return err[bool](decodingError("j2k: missing EOC"))
  if h.parts.len == 0:
    return err[bool](decodingError("j2k: no tile parts"))
  ok(true)

proc parseCodestream*(data: openArray[uint8]): ImageResult[J2kHeaders] =
  if data.len < 4:
    return err[J2kHeaders](decodingError("j2k: too short"))
  if u16be(data, 0) != MkSoc:
    return err[J2kHeaders](decodingError("j2k: missing SOC"))
  var h: J2kHeaders
  var pos = 2
  let m = parseMainHeader(data, pos, h)
  if not m.ok: return err[J2kHeaders](m.err)
  let t = parseTileParts(data, pos, h)
  if not t.ok: return err[J2kHeaders](t.err)
  # trailing bytes after EOC are tolerated only if empty (strict like ref)
  if pos != data.len:
    return err[J2kHeaders](decodingError("j2k: trailing bytes after EOC"))
  # canvas limits gate (9/7 + HT decode lands next; M1 only frames)
  let (w, hgt) = frameSize(h.siz)
  if w <= 0 or hgt <= 0 or w > 65535 or hgt > 65535:
    return err[J2kHeaders](limitError(lkDimensionError, "j2k: bad canvas"))
  ok(h)

# ---------- Tier-1: MQ arithmetic decoder ----------

const MqStates*: array[47, tuple[qe: uint16, nmps, nlps: uint8, sw: bool]] = [
  (0x5601'u16, 1'u8, 1'u8, true),
  (0x3401'u16, 2'u8, 6'u8, false),
  (0x1801'u16, 3'u8, 9'u8, false),
  (0x0ac1'u16, 4'u8, 12'u8, false),
  (0x0521'u16, 5'u8, 29'u8, false),
  (0x0221'u16, 38'u8, 33'u8, false),
  (0x5601'u16, 7'u8, 6'u8, true),
  (0x5401'u16, 8'u8, 14'u8, false),
  (0x4801'u16, 9'u8, 14'u8, false),
  (0x3801'u16, 10'u8, 14'u8, false),
  (0x3001'u16, 11'u8, 17'u8, false),
  (0x2401'u16, 12'u8, 18'u8, false),
  (0x1c01'u16, 13'u8, 20'u8, false),
  (0x1601'u16, 29'u8, 21'u8, false),
  (0x5601'u16, 15'u8, 14'u8, true),
  (0x5401'u16, 16'u8, 14'u8, false),
  (0x5101'u16, 17'u8, 15'u8, false),
  (0x4801'u16, 18'u8, 16'u8, false),
  (0x3801'u16, 19'u8, 17'u8, false),
  (0x3401'u16, 20'u8, 18'u8, false),
  (0x3001'u16, 21'u8, 19'u8, false),
  (0x2801'u16, 22'u8, 19'u8, false),
  (0x2401'u16, 23'u8, 20'u8, false),
  (0x2201'u16, 24'u8, 21'u8, false),
  (0x1c01'u16, 25'u8, 22'u8, false),
  (0x1801'u16, 26'u8, 23'u8, false),
  (0x1601'u16, 27'u8, 24'u8, false),
  (0x1401'u16, 28'u8, 25'u8, false),
  (0x1201'u16, 29'u8, 26'u8, false),
  (0x1101'u16, 30'u8, 27'u8, false),
  (0x0ac1'u16, 31'u8, 28'u8, false),
  (0x09c1'u16, 32'u8, 29'u8, false),
  (0x08a1'u16, 33'u8, 30'u8, false),
  (0x0521'u16, 34'u8, 31'u8, false),
  (0x0441'u16, 35'u8, 32'u8, false),
  (0x02a1'u16, 36'u8, 33'u8, false),
  (0x0221'u16, 37'u8, 34'u8, false),
  (0x0141'u16, 38'u8, 35'u8, false),
  (0x0111'u16, 39'u8, 36'u8, false),
  (0x0085'u16, 40'u8, 37'u8, false),
  (0x0049'u16, 41'u8, 38'u8, false),
  (0x0025'u16, 42'u8, 39'u8, false),
  (0x0015'u16, 43'u8, 40'u8, false),
  (0x0009'u16, 44'u8, 41'u8, false),
  (0x0005'u16, 45'u8, 42'u8, false),
  (0x0001'u16, 45'u8, 43'u8, false),
  (0x5601'u16, 46'u8, 46'u8, false),
]

type MqCtx = tuple[state: uint8, mps: bool]

type MqDec = object
  data: seq[uint8]   # owned copy of the segment bytes (segments are small)
  bi: int            # byte index
  a: uint32
  c: uint32
  ct: uint8
  ctx: array[19, MqCtx]

proc mqByteIn(m: var MqDec): bool =
  ## Returns false on arithmetic overflow (caller maps to decodingError).
  let cur: uint8 =
    if m.bi < m.data.len: m.data[m.bi] else: 0xFF
  let nxt: uint8 =
    if m.bi + 1 < m.data.len: m.data[m.bi + 1] else: 0xFF
  var advanced = true
  if cur == 0xFF and nxt > 0x8F:
    advanced = false # marker padding class: no advance, no addend
  else:
    if cur == 0xFF:
      m.c += uint32(nxt) shl 9
    else:
      m.c += uint32(nxt) shl 8
  if advanced:
    inc m.bi
  if cur == 0xFF and nxt <= 0x8F:
    m.ct = 7
  else:
    m.ct = 8
  true

proc mqInit(data: openArray[uint8]): tuple[ok: bool, m: MqDec] =
  var m = MqDec(bi: 0, a: 0x8000, c: 0, ct: 0)
  if data.len > 0:
    m.data = @(data.toOpenArray(0, data.len - 1))
  if m.data.len == 0:
    m.c = 0x00FF0000'u32
  else:
    m.c = uint32(m.data[0]) shl 16
  for i in 0..<19: m.ctx[i] = (0'u8, false)
  if not mqByteIn(m): return (false, m)
  m.c = m.c * 128
  if m.ct < 7: return (false, m)
  m.ct -= 7
  (true, m)

proc mqRenorm(m: var MqDec): bool =
  var shifts = 16
  while m.a < 0x8000:
    if shifts == 0: return false
    dec shifts
    if m.ct == 0:
      if not mqByteIn(m): return false
    if m.a > high(uint32) div 2 or m.c > high(uint32) div 2 or m.ct == 0:
      return false
    m.a *= 2; m.c *= 2; dec m.ct
  true

proc mqDecode(m: var MqDec, ci: int): tuple[ok: bool, bit: bool] =
  if ci < 0 or ci >= 19: return (false, false)
  let st = MqStates[int(m.ctx[ci].state)]
  if uint32(st.qe) > m.a: return (false, false)
  m.a -= uint32(st.qe)
  var decision: bool
  if (m.c shr 16) < uint32(st.qe):
    if m.a < uint32(st.qe):
      m.a = uint32(st.qe)
      decision = m.ctx[ci].mps
      m.ctx[ci] = (st.nmps, m.ctx[ci].mps)
    else:
      m.a = uint32(st.qe)
      decision = not m.ctx[ci].mps
      let nm = if st.sw: not m.ctx[ci].mps else: m.ctx[ci].mps
      m.ctx[ci] = (st.nlps, nm)
    if not mqRenorm(m): return (false, false)
  else:
    let qec = uint64(st.qe) * 65536
    if qec > uint64(m.c): return (false, false)
    m.c -= uint32(qec)
    if (m.a and 0x8000) == 0:
      if m.a < uint32(st.qe):
        decision = not m.ctx[ci].mps
        let nm = if st.sw: not m.ctx[ci].mps else: m.ctx[ci].mps
        m.ctx[ci] = (st.nlps, nm)
      else:
        decision = m.ctx[ci].mps
        m.ctx[ci] = (st.nmps, m.ctx[ci].mps)
      if not mqRenorm(m): return (false, false)
    else:
      decision = m.ctx[ci].mps
  (true, decision)

proc mqReset(m: var MqDec) =
  for i in 0..<19: m.ctx[i] = (0'u8, false)
  m.ctx[0] = (4'u8, false)
  m.ctx[17] = (3'u8, false)
  m.ctx[18] = (46'u8, false)

# ---------- Tier-1: raw bit reader ----------

type RawReader = object
  data: seq[uint8]
  bi: int
  cur: uint8
  rem: int  # bits remaining in cur

proc rawInit(data: openArray[uint8]): RawReader =
  var d: seq[uint8] = @[]
  if data.len > 0: d = @(data.toOpenArray(0, data.len - 1))
  RawReader(data: d, bi: 0, cur: 0, rem: 0)

proc rawBit(r: var RawReader): tuple[ok: bool, bit: bool] =
  if r.rem == 0:
    if r.bi >= r.data.len: return (false, false)
    let b = r.data[r.bi]; inc r.bi
    # bit stuffing: 0xFF must be followed by stuffed byte with MSB 0;
    # only 7 bits of the follower are data.
    if r.bi >= 2 and r.data[r.bi - 2] == 0xFF:
      # previous byte was FF: current follows it
      if (b and 0x80) != 0: return (false, false)
      r.cur = b; r.rem = 7
    else:
      r.cur = b; r.rem = 8
      if b == 0xFF:
        # need to check follower at next load; handled by the branch above
        discard
  dec r.rem
  (true, ((r.cur shr r.rem) and 1) != 0)

# ---------- Tier-1: code-block plane + legacy passes ----------

type J2kOrient = enum
  orLL, orLH, orHL, orHH

type CbCoeff = object
  mag: int64
  neg: bool
  sig: bool
  refined: bool
  legBp: int  # legacy bitplane of last touch, -1 if none

type CbPlane = object
  w*, h*: int
  c*: seq[CbCoeff]

proc cbIdx(p: CbPlane, x, y: int): int = y * p.w + x

proc cbNeigh(p: CbPlane, x, y: int, vcausal: bool,
    hs, vs, ds: var int, hb, vb: var int) =
  ## Neighbor summary: significant counts (h/v/diag) and sign balances.
  ## Below-row neighbors excluded on stripe-last rows when vcausal.
  hs = 0; vs = 0; ds = 0; hb = 0; vb = 0
  for dy in -1..1:
    for dx in -1..1:
      if dx == 0 and dy == 0: continue
      let nx = x + dx; let ny = y + dy
      if nx < 0 or ny < 0 or nx >= p.w or ny >= p.h: continue
      if vcausal and dy == 1 and (y mod 4) == 3: continue
      let cc = p.c[ny * p.w + nx]
      if not cc.sig: continue
      let s = if cc.neg: -1 else: 1
      if dx != 0 and dy == 0: hs += 1; hb += s
      elif dx == 0 and dy != 0: vs += 1; vb += s
      else: ds += 1

func zeroCtx(h, v, d: int, hh: bool): int =
  if hh:
    let direct = h + v
    if d == 0:
      if direct == 0: 0 elif direct == 1: 1 else: 2
    elif d == 1:
      if direct == 0: 3 elif direct == 1: 4 else: 5
    elif d == 2:
      if direct == 0: 6 else: 7
    else: 8
  elif h == 0:
    if v == 0:
      if d == 0: 0 elif d == 1: 1 else: 2
    elif v == 1: 3
    else: 4
  elif h == 1:
    if v == 0:
      if d == 0: 5 else: 6
    else: 7
  else: 8

func signCtx(hb, vb: int): tuple[ctx: int, predNeg: bool] =
  let sh: int = if hb < 0: -1 elif hb > 0: 1 else: 0
  let sv: int = if vb < 0: -1 elif vb > 0: 1 else: 0
  var ho = sh; var vo = sv
  if ho < 0:
    ho = 1
    vo = if sv < 0: 1 elif sv > 0: -1 else: 0
  # NOTE: predicted_negative uses the ORIGINAL balances (ref state.rs:260).
  let pred = hb < 0 or (hb == 0 and vb < 0)
  let off =
    if ho == 0:
      if vo == 0: 0 else: 1
    elif vo < 0: 2
    elif vo == 0: 3
    else: 4
  (9 + off, pred)

type BitplaneState = object
  bp: int
  sigBefore: seq[bool]
  visited: seq[bool]

proc newBpState(p: CbPlane, bp: int): BitplaneState =
  var sb = newSeq[bool](p.c.len)
  for i, cc in p.c: sb[i] = cc.sig
  BitplaneState(bp: bp, sigBefore: sb, visited: newSeq[bool](p.c.len))

type SymKind = enum
  skMq, skRaw

type SymReader = object
  case kind: SymKind
  of skMq: mq: MqDec
  of skRaw: raw: RawReader
  ok: bool

proc symBit(s: var SymReader, ctx: int): tuple[ok: bool, bit: bool] =
  if not s.ok: return (false, false)
  case s.kind
  of skMq:
    let r = mqDecode(s.mq, ctx)
    if not r.ok: s.ok = false
    (r.ok, r.bit)
  of skRaw:
    let r = rawBit(s.raw)
    if not r.ok: s.ok = false
    (r.ok, r.bit)

proc isRaw(s: SymReader): bool = s.kind == skRaw

proc decodeSign(p: var CbPlane, s: var SymReader, x, y: int, bp: int,
    hb, vb: int): bool =
  let (ctx, pred) = signCtx(hb, vb)
  let r = symBit(s, ctx)
  if not r.ok: return false
  var neg: bool
  if isRaw(s): neg = r.bit
  else: neg = r.bit xor pred
  let i = cbIdx(p, x, y)
  p.c[i].mag = 1'i64 shl bp
  p.c[i].neg = neg
  p.c[i].sig = true
  p.c[i].refined = false
  p.c[i].legBp = bp
  true

proc sigPropPass(p: var CbPlane, st: var BitplaneState, s: var SymReader,
    orient: J2kOrient, vcausal: bool): bool =
  var y0 = 0
  while y0 < p.h:
    let rows = min(4, p.h - y0)
    for x in 0..<p.w:
      for r in 0..<rows:
        let y = y0 + r
        let i = cbIdx(p, x, y)
        if p.c[i].sig: continue
        var hs, vs, ds, hb, vb: int
        cbNeigh(p, x, y, vcausal, hs, vs, ds, hb, vb)
        if hs + vs + ds == 0: continue
        let zc =
          if orient == orHH: zeroCtx(hs, vs, ds, true)
          elif orient == orHL: zeroCtx(vs, hs, ds, false)
          else: zeroCtx(hs, vs, ds, false)
        let rr = symBit(s, zc)
        if not rr.ok: return false
        st.visited[i] = true
        if rr.bit:
          if not decodeSign(p, s, x, y, st.bp, hb, vb): return false
    y0 += rows
  true

proc magRefPass(p: var CbPlane, st: BitplaneState, s: var SymReader,
    vcausal: bool): bool =
  var y0 = 0
  while y0 < p.h:
    let rows = min(4, p.h - y0)
    for x in 0..<p.w:
      for r in 0..<rows:
        let y = y0 + r
        let i = cbIdx(p, x, y)
        if not st.sigBefore[i]: continue
        var hs, vs, ds, hb, vb: int
        cbNeigh(p, x, y, vcausal, hs, vs, ds, hb, vb)
        let ctx =
          if p.c[i].refined: 16
          elif hs + vs + ds > 0: 15
          else: 14
        let rr = symBit(s, ctx)
        if not rr.ok: return false
        if rr.bit: p.c[i].mag += 1'i64 shl st.bp
        p.c[i].refined = true
        p.c[i].legBp = st.bp
    y0 += rows
  true

proc cleanupPass(p: var CbPlane, st: var BitplaneState, s: var SymReader,
    orient: J2kOrient, vcausal, segSym: bool): bool =
  var y0 = 0
  while y0 < p.h:
    let rows = min(4, p.h - y0)
    for x in 0..<p.w:
      var canRun = rows == 4
      if canRun:
        for r in 0..<4:
          let y = y0 + r
          let i = cbIdx(p, x, y)
          if p.c[i].sig or st.visited[i]:
            canRun = false; break
          var hs, vs, ds, hb, vb: int
          cbNeigh(p, x, y, vcausal, hs, vs, ds, hb, vb)
          if hs + vs + ds != 0:
            canRun = false; break
      if canRun:
        let r0 = symBit(s, 17)
        if not r0.ok: return false
        if r0.bit:
          let rh = symBit(s, 18)
          let rl = symBit(s, 18)
          if not rh.ok or not rl.ok: return false
          let rl2 = if rh.bit: (if rl.bit: 3 else: 2)
            elif rl.bit: 1 else: 0
          let y = y0 + rl2
          var hs, vs, ds, hb, vb: int
          cbNeigh(p, x, y, vcausal, hs, vs, ds, hb, vb)
          if not decodeSign(p, s, x, y, st.bp, hb, vb): return false
          for r in rl2+1..<4:
            let yy = y0 + r
            var h2, v2, d2, hb2, vb2: int
            cbNeigh(p, x, yy, vcausal, h2, v2, d2, hb2, vb2)
            let zc =
              if orient == orHH: zeroCtx(h2, v2, d2, true)
              elif orient == orHL: zeroCtx(v2, h2, d2, false)
              else: zeroCtx(h2, v2, d2, false)
            let rr = symBit(s, zc)
            if not rr.ok: return false
            if rr.bit:
              if not decodeSign(p, s, x, yy, st.bp, hb2, vb2): return false
      else:
        for r in 0..<rows:
          let y = y0 + r
          let i = cbIdx(p, x, y)
          if p.c[i].sig or st.visited[i]: continue
          var hs, vs, ds, hb, vb: int
          cbNeigh(p, x, y, vcausal, hs, vs, ds, hb, vb)
          let zc =
            if orient == orHH: zeroCtx(hs, vs, ds, true)
            elif orient == orHL: zeroCtx(vs, hs, ds, false)
            else: zeroCtx(hs, vs, ds, false)
          let rr = symBit(s, zc)
          if not rr.ok: return false
          if rr.bit:
            if not decodeSign(p, s, x, y, st.bp, hb, vb): return false
    y0 += rows
  if segSym:
    let a = symBit(s, 18); let b = symBit(s, 18)
    let c = symBit(s, 18); let d = symBit(s, 18)
    if not a.ok or not b.ok or not c.ok or not d.ok: return false
    if not (a.bit and not b.bit and c.bit and not d.bit): return false
  true

# ---------- Tier-1: code-block segment driver ----------

type CbWork = object
  plane: CbPlane
  orient: J2kOrient
  topBp: int       # effective top bitplane B' = (sig-1) - zero
  maxPasses: int
  nextPass: int
  curBp: int       # bitplane of active BitplaneState, -2 = none
  bst: BitplaneState
  mqCtx: array[19, MqCtx]
  hasMqCtx: bool

proc passBitplane(topBp, pass: int): int =
  topBp - ((pass + 2) div 3)

proc passKind(pass: int): int =
  ## 0 sigprop, 1 magref, 2 cleanup. pass 0 -> cleanup.
  if pass == 0: 2 else: (pass - 1) mod 3

proc decodeCbSegment(w: var CbWork, data: openArray[uint8], passes: int,
    bypass, reset, termAll, vcausal, predictable, segSym: bool,
    useRaw: bool): bool =
  ## Decode `passes` passes from one segment. Fresh MQ coder per segment;
  ## contexts persist across segments unless style.reset.
  ## Segmentation symbols attach to cleanup passes when segSym is set.
  var sym: SymReader
  if useRaw:
    sym = SymReader(kind: skRaw, raw: rawInit(data), ok: true)
  else:
    let (ok, m0) = mqInit(data)
    if not ok: return false
    var m = m0
    if w.hasMqCtx and not reset:
      m.ctx = w.mqCtx
    else:
      mqReset(m)
    sym = SymReader(kind: skMq, mq: m, ok: true)
  for k in 0..<passes:
    let pass = w.nextPass + k
    let bp = passBitplane(w.topBp, pass)
    if bp < 0 or bp > 64: return false
    if bp != w.curBp:
      w.bst = newBpState(w.plane, bp)
      w.curBp = bp
    let kind = passKind(pass)
    var okp = false
    if kind == 0:
      okp = sigPropPass(w.plane, w.bst, sym, w.orient, vcausal)
    elif kind == 1:
      okp = magRefPass(w.plane, w.bst, sym, vcausal)
    else:
      # segsym only when the segment ends on a cleanup pass and the
      # style demands it (matches pass_plan expect_segmentation_symbol).
      let wantSeg = segSym and (k == passes - 1) and (kind == 2)
      okp = cleanupPass(w.plane, w.bst, sym, w.orient, vcausal, wantSeg)
    if not okp or not sym.ok: return false
  if not sym.ok: return false
  if sym.kind == skMq:
    w.mqCtx = sym.mq.ctx
    w.hasMqCtx = true
  w.nextPass += passes
  if reset:
    w.hasMqCtx = false
  true

# ---------- packets: bit reader + tag trees ----------

type PktReader = object
  data: seq[uint8]
  bi: int
  cur: uint8
  rem: int
  prevFF: bool
  ok: bool

proc pktInit(data: openArray[uint8], off, ln: int): PktReader =
  var d: seq[uint8] = @[]
  if ln > 0:
    d = @(data.toOpenArray(off, off + ln - 1))
  PktReader(data: d, bi: 0, cur: 0, rem: 0, prevFF: false, ok: true)

proc pktLoad(r: var PktReader): bool =
  if r.bi >= r.data.len: return false
  let b = r.data[r.bi]; inc r.bi
  if r.prevFF and (b and 0x80) != 0: return false
  r.cur = b
  r.rem = if r.prevFF: 7 else: 8
  r.prevFF = b == 0xFF
  true

proc pktBit(r: var PktReader): tuple[ok: bool, bit: bool] =
  if not r.ok: return (false, false)
  if r.rem == 0:
    if not pktLoad(r):
      r.ok = false
      return (false, false)
  dec r.rem
  (true, ((r.cur shr r.rem) and 1) != 0)

proc pktBits(r: var PktReader, n: int): tuple[ok: bool, v: uint32] =
  var v = 0'u32
  for _ in 0..<n:
    let b = pktBit(r)
    if not b.ok: return (false, 0)
    v = (v shl 1) or (if b.bit: 1'u32 else: 0'u32)
  (true, v)

proc pktAlign(r: var PktReader) =
  ## End of packet header: consume the stuffed follower if the last byte
  ## was 0xFF, then drop to byte boundary (ref finish_packet_header).
  if r.prevFF:
    discard pktLoad(r)
  r.rem = 0

type TagTree = object
  # levels[0] = finest (leaf res); lw[i]/lh[i] = nodes per level.
  lw, lh: seq[int]
  low: seq[seq[int]]  # per level, per node: current low threshold
  val: seq[seq[int]]  # per level, per node: current value (-1 unknown)

proc tagBuild(w, h: int): TagTree =
  var ws: seq[int] = @[]
  var hs: seq[int] = @[]
  var cw = w; var ch = h
  ws.add(cw); hs.add(ch)
  while cw > 1 or ch > 1:
    cw = (cw + 1) div 2; ch = (ch + 1) div 2
    ws.add(cw); hs.add(ch)
  var low: seq[seq[int]] = @[]
  var val: seq[seq[int]] = @[]
  for i in 0..<ws.len:
    low.add(newSeq[int](ws[i] * hs[i]))
    var v = newSeq[int](ws[i] * hs[i])
    for k in 0..<v.len: v[k] = -1
    val.add(v)
  TagTree(lw: ws, lh: hs, low: low, val: val)

proc tagDecode(t: var TagTree, x, y, thresh: int,
    r: var PktReader): tuple[ok: bool, below: bool, value: int] =
  ## Reference packet/tag_tree.rs decode: root->leaf carrying inherited
  ## low; per node emit bits while low < thresh and low < value.
  ## bit 1 -> value = low; bit 0 -> low += 1. Decided value >= thresh
  ## (or threshold reached undecided) aborts the whole decode as
  ## not-below-threshold without touching deeper levels.
  let nl = t.lw.len
  var pathX = newSeq[int](nl)
  var pathY = newSeq[int](nl)
  var cx = x; var cy = y
  for li in 0..<nl:
    pathX[li] = cx; pathY[li] = cy
    cx = cx div 2; cy = cy div 2
  var inherited = 0
  for li in countdown(nl - 1, 0):
    let idx = pathY[li] * t.lw[li] + pathX[li]
    var lo = t.low[li][idx]
    if lo < inherited: lo = inherited
    var vv = t.val[li][idx]
    while lo < thresh and (vv < 0 or lo < vv):
      let b = pktBit(r)
      if not b.ok: return (false, false, 0)
      if b.bit:
        vv = lo
        t.val[li][idx] = vv
      else:
        lo += 1
        t.low[li][idx] = lo
    if vv < 0 or vv >= thresh:
      return (true, false, 0)
    inherited = vv
  let leafV = t.val[0][y * t.lw[0] + x]
  (true, leafV >= 0 and leafV < thresh, if leafV < 0: 0 else: leafV)

# ---------- geometry: tiles, resolutions, subbands, code-blocks ----------

type SbBand = object
  orient: J2kOrient
  res: int
  x0, y0, x1, y1: int  # subband coords (absolute)
  sigBp: int           # significant bitplanes (guard + exp - 1 + roi)
  qExp: int            # quantization exponent (style 0: bitplane count ref)
  qMant: int
  dyn: int             # dynamic range = precision + gain

type TileCompGeom = object
  comp: int
  tx0, ty0, tx1, ty1: int  # tile-comp bounds in component coords
  prec: int
  signed: bool

type ResGeom = object
  r: int
  x0, y0, x1, y1: int
  bands: seq[SbBand]  # 1 (r=0) or 3

type CbGeom = object
  sb: int              # index into ResGeom.bands
  bx, by: int          # block indices within subband
  x0, y0, x1, y1: int  # block bounds in subband coords
  prec: int            # precinct index containing this block
  plx, ply: int        # leaf coords within the precinct tree

proc compTileBounds(s: J2kSiz, tx, ty, comp: int): tuple[x0, y0, x1, y1: int] =
  let tx0 = max(int(s.xtosiz) + tx * int(s.xtsiz), int(s.xosiz))
  let tx1 = min(int(s.xtosiz) + (tx + 1) * int(s.xtsiz), int(s.xsiz))
  let ty0 = max(int(s.ytosiz) + ty * int(s.ytsiz), int(s.yosiz))
  let ty1 = min(int(s.ytosiz) + (ty + 1) * int(s.ytsiz), int(s.ysiz))
  let xr = s.comps[comp].xr; let yr = s.comps[comp].yr
  let xos = int(s.xosiz); let yos = int(s.yosiz)
  (ceilDiv(tx0 - xos, xr), ceilDiv(ty0 - yos, yr),
   ceilDiv(tx1 - xos, xr), ceilDiv(ty1 - yos, yr))

proc resBounds(tx0, ty0, tx1, ty1, d, r: int): tuple[x0, y0, x1, y1: int] =
  let f = 1 shl (d - r)
  (ceilDiv(tx0, f), ceilDiv(ty0, f), ceilDiv(tx1, f), ceilDiv(ty1, f))

proc buildRes(tx0, ty0, tx1, ty1, d, r: int, quant: J2kQuant,
    prec: int, roi: int): ResGeom =
  let rb = resBounds(tx0, ty0, tx1, ty1, d, r)
  var g = ResGeom(r: r, x0: rb.x0, y0: rb.y0, x1: rb.x1, y1: rb.y1)
  if r == 0:
    let st = quant.steps[0]
    g.bands.add(SbBand(orient: orLL, res: 0, x0: rb.x0, y0: rb.y0,
      x1: rb.x1, y1: rb.y1, sigBp: quant.guard + st.exp - 1 + roi,
      qExp: st.exp, qMant: st.mant, dyn: prec))
  else:
    # detail bands at resolution r use QCD steps 1+(r-1)*3 .. +2
    # (ref quantization_step_for_subband).
    let lx0 = ceilDiv(rb.x0, 2); let ly0 = ceilDiv(rb.y0, 2)
    let lx1 = ceilDiv(rb.x1, 2); let ly1 = ceilDiv(rb.y1, 2)
    let hx0 = rb.x0 div 2; let hy0 = rb.y0 div 2
    let hx1 = rb.x1 div 2; let hy1 = rb.y1 div 2
    let base = 1 + (r - 1) * 3
    let ors = [orHL, orLH, orHH]
    let bbs = [(hx0, ly0, hx1, ly1), (lx0, hy0, lx1, hy1), (hx0, hy0, hx1, hy1)]
    let gains = [1, 1, 2]
    for k in 0..2:
      let st = quant.steps[base + k]
      g.bands.add(SbBand(orient: ors[k], res: r,
        x0: bbs[k][0], y0: bbs[k][1], x1: bbs[k][2], y1: bbs[k][3],
        sigBp: quant.guard + st.exp - 1 + roi,
        qExp: st.exp, qMant: st.mant, dyn: prec + gains[k]))
  g

proc codeBlocksFor(sb: SbBand, cblkW, cblkH: int): seq[CbGeom] =
  ## Partition subband into nominal cblkW×cblkH blocks, grid aligned to
  ## multiples from 0 (exact for zero-origin subbands).
  var blks: seq[CbGeom] = @[]
  if sb.x1 <= sb.x0 or sb.y1 <= sb.y0: return blks
  let gx0 = sb.x0 div cblkW
  let gy0 = sb.y0 div cblkH
  let nx = ceilDiv(sb.x1, cblkW) - gx0
  let ny = ceilDiv(sb.y1, cblkH) - gy0
  for by in 0..<ny:
    for bx in 0..<nx:
      let bx0 = max(sb.x0, (gx0 + bx) * cblkW)
      let by0 = max(sb.y0, (gy0 + by) * cblkH)
      blks.add(CbGeom(bx: bx, by: by, x0: bx0, y0: by0,
        x1: min(sb.x1, bx0 + cblkW - (bx0 - (gx0 + bx) * cblkW)),
        y1: min(sb.y1, by0 + cblkH - (by0 - (gy0 + by) * cblkH))))
  blks

proc precinctGrid(rg: ResGeom, ppx, ppy: int, hasPrec: bool): tuple[nx, ny: int] =
  if not hasPrec: (1, 1)
  else: (max(1, ceilDiv(rg.x1 - rg.x0, 1 shl ppx)),
         max(1, ceilDiv(rg.y1 - rg.y0, 1 shl ppy)))

# ---------- progression iterator ----------

type PktCoord = tuple[layer, res, comp, prec: int]

proc maxPrec(pc: seq[seq[int]], r: int): int =
  var m = 0
  for c in 0..<pc.len: m = max(m, pc[c][r])
  m

proc maxPrecAll(pc: seq[seq[int]]): int =
  var m = 0
  for c in 0..<pc.len:
    for r in 0..<pc[c].len: m = max(m, pc[c][r])
  m

proc maxPrecComp(pc: seq[seq[int]], c: int): int =
  var m = 0
  for r in 0..<pc[c].len: m = max(m, pc[c][r])
  m

proc iterPackets(prog: J2kProg, layers, nres, ncomp: int,
    precCount: seq[seq[int]]): seq[PktCoord] =
  ## precCount[comp][res] = precincts in that resolution.
  var pkts: seq[PktCoord] = @[]
  case prog
  of prLrcp:
    for l in 0..<layers:
      for r in 0..<nres:
        for c in 0..<ncomp:
          for p in 0..<precCount[c][r]:
            pkts.add((l, r, c, p))
  of prRlcp:
    for r in 0..<nres:
      for l in 0..<layers:
        for c in 0..<ncomp:
          for p in 0..<precCount[c][r]:
            pkts.add((l, r, c, p))
  of prRpcl:
    for r in 0..<nres:
      for p in 0..<maxPrec(precCount, r):
        for c in 0..<ncomp:
          if p < precCount[c][r]:
            for l in 0..<layers:
              pkts.add((l, r, c, p))
  of prPcrl:
    for p in 0..<maxPrecAll(precCount):
      for c in 0..<ncomp:
        for r in 0..<nres:
          if p < precCount[c][r]:
            for l in 0..<layers:
              pkts.add((l, r, c, p))
  of prCprl:
    for c in 0..<ncomp:
      for p in 0..<maxPrecComp(precCount, c):
        for r in 0..<nres:
          if p < precCount[c][r]:
            for l in 0..<layers:
              pkts.add((l, r, c, p))
  pkts

proc iterPacketsPoc(windows: seq[tuple[rS, cS, lE, rE, cE: int, pr: J2kProg]],
    layers, nres, ncomp: int, precCount: seq[seq[int]]): seq[PktCoord] =
  ## POC windows in order; layer range of window i is
  ## [prev.lE (or 0), w.lE). Coordinates remapped to global; already
  ## emitted packets are skipped (reference progression_prior_contains).
  var pkts: seq[PktCoord] = @[]
  let maxP = max(1, maxPrecAll(precCount))
  var seen = newSeq[bool](layers * nres * ncomp * maxP)
  var lStart = 0
  for w in windows:
    let lEnd = min(w.lE, layers)
    if lEnd <= lStart or w.rE <= w.rS or w.cE <= w.cS:
      lStart = max(lStart, w.lE)
      continue
    let sub = precCount[w.cS..<w.cE]
    let local = iterPackets(w.pr, lEnd - lStart, w.rE - w.rS, w.cE - w.cS,
      sub)
    for (l, r, c, p) in local:
      let gl = lStart + l; let gr = w.rS + r; let gc = w.cS + c
      if gl < layers and gr < nres and gc < ncomp and
          p < precCount[gc][gr]:
        let idx = ((gl * nres + gr) * ncomp + gc) * maxP + p
        if not seen[idx]:
          seen[idx] = true
          pkts.add((gl, gr, gc, p))
    lStart = max(lStart, w.lE)
  pkts

# ---------- tile decode state ----------

type CbPktState = object
  included: bool
  zero: int
  lblock: int   # packet Lblock starts at 3 (ref code_block_packet_state_new)
  totalPasses: int
  work: CbWork
  hasWork: bool

proc newCbPktState(): CbPktState =
  CbPktState(included: false, zero: -1, lblock: 3, totalPasses: 0,
    hasWork: false)

type PrecSub = object
  ## One subband's blocks within one precinct, with its own tag trees
  ## (opj + reference use per-precinct trees, not per-subband).
  blkIdx: seq[int]   # indices into the subband's block list (raster)
  nx*, ny*: int      # tree grid dims
  inclTree*, zeroTree*: TagTree

type SubbandState = object
  geom: SbBand
  blocks: seq[CbGeom]
  pkt: seq[CbPktState]

type TileResState = object
  geom: ResGeom
  subs: seq[SubbandState]
  precNx, precNy: int   # precinct grid dims for this resolution
  ppx, ppy: int
  precs: seq[seq[PrecSub]]  # precs[p][si]: subband si's blocks in precinct p

type TileCompState = object
  geom: TileCompGeom
  style: J2kCodingStyle
  quant: J2kQuant
  roi: int
  res: seq[TileResState]

type TileState = object
  idx: int
  tx0, ty0: int       # tile origin in canvas (reference grid)
  comps: seq[TileCompState]

proc precinctOf(rg: ResGeom, pnx, pny, ppx, ppy: int, sb: SbBand,
    b: CbGeom, resIdx: int): int =
  ## Precinct index (py*nx + px) containing a code-block, using
  ## subband-scale precinct sizes (opj tcd: precinct grid step is
  ## 2^PPx at res 0 but 2^(PPx-1) within res>0 subbands, matching the
  ## halved subband sampling; the code-block clamp in buildTileState
  ## uses the same rule so blocks never span precincts).
  ## Falls back to precinct 0 for degenerate (PPx=0) configs.
  let subExpX = ppx - (if resIdx == 0: 0 else: 1)
  let subExpY = ppy - (if resIdx == 0: 0 else: 1)
  if subExpX < 0 or subExpY < 0:
    return 0
  let pw = 1 shl subExpX; let ph = 1 shl subExpY
  let nx = max(1, (sb.x1 - sb.x0 + pw - 1) div pw)
  let ny = max(1, (sb.y1 - sb.y0 + ph - 1) div ph)
  var px = (b.x0 - sb.x0) div pw
  var py = (b.y0 - sb.y0) div ph
  px = clamp(px, 0, nx - 1)
  py = clamp(py, 0, ny - 1)
  # map to res-scale precinct index (grids coincide for aligned origins)
  let rx = clamp(px, 0, pnx - 1)
  let ry = clamp(py, 0, pny - 1)
  ry * pnx + rx

# ---------- packets: header parse + contributions ----------

func floorLog2(v: int): int =
  var x = v; var r = -1
  while x > 0: x = x shr 1; inc r
  max(r, 0)

proc readNewPasses(r: var PktReader): tuple[ok: bool, n: int] =
  let b0 = pktBit(r)
  if not b0.ok: return (false, 0)
  if not b0.bit: return (true, 1)
  let b1 = pktBit(r)
  if not b1.ok: return (false, 0)
  if not b1.bit: return (true, 2)
  let s = pktBits(r, 2)
  if not s.ok: return (false, 0)
  case s.v
  of 0: (true, 3)
  of 1: (true, 4)
  of 2: (true, 5)
  else:
    let e = pktBits(r, 5)
    if not e.ok: return (false, 0)
    if e.v == 31:
      let e2 = pktBits(r, 7)
      if not e2.ok: return (false, 0)
      let n = int(e2.v) + 37
      if n > 164: (false, 0) else: (true, n)
    else:
      (true, int(e.v) + 6)

proc segPassesLegacy(firstPass, remaining: int, bypass, termAll: bool): int =
  if remaining <= 0: return 0
  if termAll: return 1
  if not bypass: return remaining
  if firstPass < 10: return min(remaining, 10 - firstPass)
  case passKind(firstPass)
  of 0: min(remaining, 2)
  else: 1

type CbSeg = tuple[passes: int, length: int, useRaw: bool]

proc parseBlockContrib(st: var CbPktState, inclT, zeroT: var TagTree,
    lx, ly, layer, maxZero: int, r: var PktReader, style: J2kCodingStyle,
    firstPassTotal: int): tuple[ok, includedNow: bool, segs: seq[CbSeg]] =
  ## Parse one code-block's packet contribution. Returns segments to feed.
  var segs: seq[CbSeg] = @[]
  if not st.included:
    let inc = tagDecode(inclT, lx, ly, layer + 1, r)
    if not inc.ok: return (false, false, segs)
    if not inc.below: return (true, false, segs)
    st.included = true
    # zero bitplanes
    var t = 1
    var zb = -1
    while true:
      if t > maxZero + 1: return (false, false, segs)
      let z = tagDecode(zeroT, lx, ly, t, r)
      if not z.ok: return (false, false, segs)
      if z.below:
        zb = z.value
        break
      inc t
    if zb < 0 or zb >= maxZero: return (false, false, segs)
    st.zero = zb
  else:
    let b = pktBit(r)
    if not b.ok: return (false, false, segs)
    if not b.bit: return (true, false, segs)
  let np = readNewPasses(r)
  if not np.ok or np.n < 1 or np.n > 164: return (false, false, segs)
  # Lblock increments
  var guard = 0
  while true:
    let b = pktBit(r)
    if not b.ok: return (false, false, segs)
    if not b.bit: break
    inc st.lblock
    inc guard
    if st.lblock > 31 or guard > 32: return (false, false, segs)
  # HT-selected blocks are a clean Unsupported in this phase; legacy only.
  if style.ht or style.mixed:
    return (false, false, segs)
  var accounted = 0
  while accounted < np.n:
    let fp = firstPassTotal + accounted
    let rem = np.n - accounted
    let ps = segPassesLegacy(fp, rem, style.selBypass, style.termAll)
    if ps <= 0 or ps > rem: return (false, false, segs)
    let lb = st.lblock + floorLog2(ps)
    if lb > 32: return (false, false, segs)
    let ln = pktBits(r, lb)
    if not ln.ok: return (false, false, segs)
    let raw = style.selBypass and fp >= 10 and passKind(fp) != 2
    segs.add((passes: ps, length: int(ln.v), useRaw: raw))
    accounted += ps
  (true, true, segs)

type PktFeed = tuple[blk, sb: int, segs: seq[CbSeg]]

proc parsePacket(data: openArray[uint8], pos: var int, dataEnd: int,
    coord: PktCoord, tile: var TileState, sopExpected: var int,
    style: J2kCodingStyle): tuple[ok: bool, feeds: seq[PktFeed],
    bodyLen: int] =
  ## Parse one packet header at pos; returns per-block feeds + total body.
  ## Every packet starts with a present bit (empty packets carry nothing
  ## else); SOP precedes it and EPH follows the header unconditionally.
  var feeds: seq[PktFeed] = @[]
  if style.sop:
    # SOP = FF 91 + Lsop(2, must be 4) + Nsop(2). 6 bytes total; Nsop
    # counts packets within the tile from 0 (ref precinct.rs:1365).
    if pos + 6 > dataEnd: return (false, feeds, 0)
    if not (data[pos] == 0xFF and data[pos+1] == 0x91 and
        data[pos+2] == 0 and data[pos+3] == 4):
      return (false, feeds, 0)
    let ns = (int(data[pos+4]) shl 8) or int(data[pos+5])
    if ns != sopExpected: return (false, feeds, 0)
    inc sopExpected
    pos += 6
  var r = pktInit(data, pos, dataEnd - pos)
  let present = pktBit(r)
  if not present.ok: return (false, feeds, 0)
  if not present.bit:
    # empty packet: align past the present bit, then EPH as usual.
    pktAlign(r)
    if not r.ok: return (false, feeds, 0)
    pos += r.bi
    if style.eph:
      if pos + 2 > dataEnd: return (false, feeds, 0)
      if not (data[pos] == 0xFF and data[pos+1] == 0x92):
        return (false, feeds, 0)
      pos += 2
    return (true, feeds, 0)
  # gather (subband, block) list in packet order for this precinct,
  # with per-precinct tag trees + precinct-local leaf coords.
  var order: seq[tuple[sb, blk: int]] = @[]
  let tc = tile.comps[coord.comp]
  let rg = tc.res[coord.res]
  if coord.prec < 0 or coord.prec >= rg.precs.len:
    return (false, feeds, 0)
  for si in 0..<rg.subs.len:
    for bi in rg.precs[coord.prec][si].blkIdx:
      order.add((si, bi))
  if order.len == 0:
    # present bit set but no blocks in this precinct: malformed.
    return (false, feeds, 0)
  var totalBody = 0
  for (si, bi) in order:
    let b = tile.comps[coord.comp].res[coord.res].subs[si].blocks[bi]
    let c = parseBlockContrib(
      tile.comps[coord.comp].res[coord.res].subs[si].pkt[bi],
      tile.comps[coord.comp].res[coord.res].precs[coord.prec][si].inclTree,
      tile.comps[coord.comp].res[coord.res].precs[coord.prec][si].zeroTree,
      b.plx, b.ply, coord.layer,
      tile.comps[coord.comp].res[coord.res].subs[si].geom.sigBp,
      r, style,
      tile.comps[coord.comp].res[coord.res].subs[si].pkt[bi].totalPasses)
    if not c.ok: return (false, feeds, 0)
    if c.includedNow:
      var np = 0
      for s in c.segs:
        totalBody += s.length
        np += s.passes
      feeds.add((blk: bi, sb: si, segs: c.segs))
      tile.comps[coord.comp].res[coord.res].subs[si].pkt[bi].totalPasses += np
  # byte-align + EPH
  pktAlign(r)
  if not r.ok: return (false, feeds, 0)
  pos += r.bi
  if style.eph:
    if pos + 2 > dataEnd: return (false, feeds, 0)
    if not (data[pos] == 0xFF and data[pos+1] == 0x92):
      return (false, feeds, 0)
    pos += 2
  (true, feeds, totalBody)

# ---------- orchestration: per-comp config, tile build, IDWT ----------

proc compStyle(h: J2kHeaders, comp: int): J2kCodingStyle =
  for e in h.cocs:
    if e.comp == comp: return e.st
  h.cod

proc compQuant(h: J2kHeaders, comp: int): J2kQuant =
  for e in h.qccs:
    if e.comp == comp: return e.q
  h.qcd

proc compRoi(h: J2kHeaders, comp: int): int =
  for e in h.rgn:
    if e.comp == comp: return e.shift
  0

proc buildTileState(h: J2kHeaders, tx, ty: int): tuple[ok: bool,
    err: ImageError, tile: TileState] =
  var tile = TileState(tx0: max(int(h.siz.xtosiz) + tx * int(h.siz.xtsiz),
    int(h.siz.xosiz)), ty0: max(int(h.siz.ytosiz) + ty * int(h.siz.ytsiz),
    int(h.siz.yosiz)))
  let nc = h.siz.comps.len
  for c in 0..<nc:
    let st = compStyle(h, c)
    let q = compQuant(h, c)
    if q.style != 0:
      return (false, unsupportedError(ukGenericFeature,
        "j2k: only no-quantization (reversible) in this phase"), tile)
    if st.dlevels < 0 or st.dlevels > 32:
      return (false, decodingError("j2k: bad levels"), tile)
    if 1 + 3 * st.dlevels != q.steps.len:
      return (false, decodingError("j2k: quant steps mismatch"), tile)
    let b = compTileBounds(h.siz, tx, ty, c)
    if b.x1 < b.x0 or b.y1 < b.y0:
      return (false, decodingError("j2k: bad tile-comp bounds"), tile)
    var tc = TileCompState(
      geom: TileCompGeom(comp: c, tx0: b.x0, ty0: b.y0, tx1: b.x1,
        ty1: b.y1, prec: h.siz.comps[c].prec,
        signed: h.siz.comps[c].signed),
      style: st, quant: q, roi: compRoi(h, c))
    for r in 0..st.dlevels:
      var rg = buildRes(b.x0, b.y0, b.x1, b.y1, st.dlevels, r, q,
        h.siz.comps[c].prec, tc.roi)
      var pg = precinctGrid(rg, 0, 0, false)
      var ppx = 15; var ppy = 15
      if st.precincts:
        if r < st.ppx.len:
          pg = precinctGrid(rg, st.ppx[r], st.ppy[r], true)
          ppx = st.ppx[r]; ppy = st.ppy[r]
      # opj-compatible block/precinct rule: code-blocks never span a
      # precinct — clamp the nominal size to the precinct grid
      # (res0: 2^PPx; res>0: half-scale subbands use 2^(PPx-1)).
      # With default 2^15 precincts this keeps the nominal size.
      var bwExp = st.xcb + 2; var bhExp = st.ycb + 2
      let cx = if r == 0: ppx elif ppx == 0: 99 else: ppx - 1
      let cy = if r == 0: ppy elif ppy == 0: 99 else: ppy - 1
      bwExp = min(bwExp, cx); bhExp = min(bhExp, cy)
      let bw = 1 shl bwExp; let bh = 1 shl bhExp
      var trs = TileResState(geom: rg, precNx: pg.nx, precNy: pg.ny,
        ppx: 0, ppy: 0)
      if st.precincts and r < st.ppx.len:
        trs.ppx = st.ppx[r]; trs.ppy = st.ppy[r]
      for si in 0..<rg.bands.len:
        let sb = rg.bands[si]
        let blks = codeBlocksFor(sb, bw, bh)
        var ss = SubbandState(geom: sb, blocks: blks)
        ss.pkt = newSeq[CbPktState](blks.len)
        for bi in 0..<ss.pkt.len: ss.pkt[bi] = newCbPktState()
        trs.subs.add(ss)
      # assign blocks to precincts + build per-precinct tag trees
      # (opj/reference use per-precinct trees, not per-subband).
      let np = pg.nx * pg.ny
      let rppx = if st.precincts and r < st.ppx.len: st.ppx[r] else: 15
      let rppy = if st.precincts and r < st.ppx.len: st.ppy[r] else: 15
      for si in 0..<trs.subs.len:
        let sb = trs.subs[si].geom
        for bi in 0..<trs.subs[si].blocks.len:
          var blk = trs.subs[si].blocks[bi]
          blk.sb = si
          blk.prec = precinctOf(rg, pg.nx, pg.ny, rppx, rppy, sb, blk, r)
          trs.subs[si].blocks[bi] = blk
      var precs: seq[seq[PrecSub]] = @[]
      for p in 0..<np:
        var prow: seq[PrecSub] = @[]
        for si in 0..<trs.subs.len:
          var ps = PrecSub(nx: 1, ny: 1)
          var minBx = high(int); var minBy = high(int)
          var maxBx = -1; var maxBy = -1
          for bi in 0..<trs.subs[si].blocks.len:
            if trs.subs[si].blocks[bi].prec == p:
              ps.blkIdx.add(bi)
              minBx = min(minBx, trs.subs[si].blocks[bi].bx)
              minBy = min(minBy, trs.subs[si].blocks[bi].by)
              maxBx = max(maxBx, trs.subs[si].blocks[bi].bx)
              maxBy = max(maxBy, trs.subs[si].blocks[bi].by)
          if ps.blkIdx.len > 0:
            ps.nx = max(1, maxBx - minBx + 1)
            ps.ny = max(1, maxBy - minBy + 1)
            for k in 0..<ps.blkIdx.len:
              let bi = ps.blkIdx[k]
              trs.subs[si].blocks[bi].plx =
                trs.subs[si].blocks[bi].bx - minBx
              trs.subs[si].blocks[bi].ply =
                trs.subs[si].blocks[bi].by - minBy
          ps.inclTree = tagBuild(max(ps.nx, 1), max(ps.ny, 1))
          ps.zeroTree = tagBuild(max(ps.nx, 1), max(ps.ny, 1))
          prow.add(ps)
        precs.add(prow)
      trs.precs = move(precs)
      tc.res.add(trs)
    tile.comps.add(tc)
  tile.idx = ty * tileGrid(h.siz).nx + tx
  (true, decodingError(""), tile)

type BandBuf = object
  x0, y0, w, h: int
  d: seq[int64]

proc bandRow(b: BandBuf, y: int): seq[int64] =
  result = newSeq[int64](b.w)
  let base = (y - b.y0) * b.w
  for i in 0..<b.w: result[i] = b.d[base + i]

proc coeffOf(st: CbPktState, blk: CbGeom, xx, yy, roi: int): int64 =
  if not st.hasWork: return 0
  let cc = st.work.plane.c[(yy - blk.y0) * st.work.plane.w + (xx - blk.x0)]
  if not cc.sig: return 0
  let mid = if cc.legBp >= 1: 1'i64 shl (cc.legBp - 1) else: 0'i64
  var v = cc.mag + mid
  if cc.neg: v = -v
  if roi > 0:
    let a = abs(v)
    if a >= (1'i64 shl roi):
      v = (if v < 0: -1'i64 else: 1'i64) * (a shr roi)
  v

proc fillBandBuf(tc: TileCompState, resIdx, subIdx: int): BandBuf =
  let sb = tc.res[resIdx].subs[subIdx].geom
  var bb = BandBuf(x0: sb.x0, y0: sb.y0, w: sb.x1 - sb.x0,
    h: sb.y1 - sb.y0,
    d: newSeq[int64](max(0, (sb.x1 - sb.x0) * (sb.y1 - sb.y0))))
  for bi in 0..<tc.res[resIdx].subs[subIdx].blocks.len:
    let blk = tc.res[resIdx].subs[subIdx].blocks[bi]
    let st = tc.res[resIdx].subs[subIdx].pkt[bi]
    for yy in blk.y0..<blk.y1:
      for xx in blk.x0..<blk.x1:
        bb.d[(yy - sb.y0) * bb.w + (xx - sb.x0)] =
          coeffOf(st, blk, xx, yy, tc.roi)
  bb

# ---------- 5/3 reversible inverse DWT (dense level buffers) ----------

proc inv53(low, high: openArray[int64], first: bool): seq[int64] =
  let nl = low.len; let nh = high.len
  let n = nl + nh
  var t = newSeq[int64](n)
  if n == 1:
    # Degenerate singleton (1-px tile-comp axis): reference engineering
    # profile applies the arithmetic half (ref wavelets.rs edge path).
    t[0] = (if nl == 1: low[0] else: high[0]) shr 1
    return t
  if first:
    for i in 0..<nl:
      t[2*i] = low[i]
      if 2*i+1 < n: t[2*i+1] = high[i]
  else:
    for i in 0..<nh:
      t[2*i] = high[i]
      if 2*i+1 < n: t[2*i+1] = low[i]
  # undo update (evens), then undo predict (odds); edges mirrored.
  for i in countup(0, n - 1, 2):
    let l = if i == 0: t[1] else: t[i-1]
    let r = if i == n - 1: t[i-1] else: t[i+1]
    t[i] -= (l + r + 2) shr 2
  for i in countup(1, n - 1, 2):
    let l = t[i-1]
    let r = if i == n - 1: t[i-1] else: t[i+1]
    t[i] += (l + r) shr 1
  t

proc idwt53Tile(D: int, ll: BandBuf, bands: seq[seq[BandBuf]],
    nx0, ny0, nx1, ny1: openArray[int]): tuple[ok: bool, buf: seq[int64]] =
  ## Inverse DWT over D levels with dense per-level buffers.
  ## nx0[k]..nx1[k] = absolute node bounds at depth k (k=0 full tile).
  ## `ll` must match node_D; bands[r] = [HL, LH, HH] at resolution r.
  ## Returns the node_0 (tile-comp) dense buffer.
  if ll.w != nx1[D] - nx0[D] or ll.h != ny1[D] - ny0[D] or ll.w < 0 or
      ll.h < 0:
    return (false, @[])
  var cur = ll.d  # dense node_D
  var cw = ll.w; var ch = ll.h
  for l in countdown(D, 1):
    let r = D - l + 1
    let W = nx1[l-1] - nx0[l-1]; let H = ny1[l-1] - ny0[l-1]
    if W <= 0 or H <= 0 or W > 1 shl 24 or H > 1 shl 24:
      return (false, @[])
    if cw != nx1[l] - nx0[l] or ch != ny1[l] - ny0[l]:
      return (false, @[])
    if r >= bands.len or bands[r].len != 3:
      return (false, @[])
    let hl = bands[r][0]; let lh = bands[r][1]; let hh = bands[r][2]
    if hl.h != ch or lh.w != cw or hh.w != W - cw or hh.h != H - ch:
      return (false, @[])
    if hl.w != W - cw or lh.h != H - ch:
      return (false, @[])
    let fx = (nx0[l-1] mod 2) == 0
    let fy = (ny0[l-1] mod 2) == 0
    # horizontal: top rows from cur + HL, bottom rows from LH + HH
    var tmp = newSeq[int64](W * H)
    for j in 0..<H:
      var row: seq[int64]
      if j < ch:
        var lo = newSeq[int64](cw)
        let base = j * cw
        for i in 0..<cw: lo[i] = cur[base + i]
        row = inv53(lo, bandRow(hl, hl.y0 + j), fx)
      else:
        let bj = j - ch
        row = inv53(bandRow(lh, lh.y0 + bj), bandRow(hh, hh.y0 + bj), fx)
      if row.len != W: return (false, @[])
      for i in 0..<W: tmp[j * W + i] = row[i]
    # vertical per column
    var outp = newSeq[int64](W * H)
    for i in 0..<W:
      var lo = newSeq[int64](ch)
      var hi = newSeq[int64](H - ch)
      for j in 0..<ch: lo[j] = tmp[j * W + i]
      for j in ch..<H: hi[j - ch] = tmp[j * W + i]
      let col = inv53(lo, hi, fy)
      if col.len != H: return (false, @[])
      for j in 0..<H: outp[j * W + i] = col[j]
    cur = move(outp)
    cw = W; ch = H
  (true, cur)

func clipU8(v: int64, prec: int, signed: bool): uint8 =
  var x = v
  if not signed: x += 1'i64 shl (prec - 1)
  let hi = (1'i64 shl prec) - 1
  let lo = if signed: -(1'i64 shl (prec - 1)) else: 0'i64
  uint8(clamp(x, lo, hi))

func clipU16(v: int64, prec: int, signed: bool): uint16 =
  var x = v
  if not signed: x += 1'i64 shl (prec - 1)
  let hi = (1'i64 shl prec) - 1
  let lo = if signed: -(1'i64 shl (prec - 1)) else: 0'i64
  uint16(clamp(x, lo, hi))

type TilePlane = object
  x0, y0, w, h: int
  d: seq[int64]

proc decodeTile(data: openArray[uint8], h: J2kHeaders, tx, ty: int):
    ImageResult[seq[TilePlane]] =
  let tc = buildTileState(h, tx, ty)
  if not tc.ok: return err[seq[TilePlane]](tc.err)
  var tile = tc.tile
  let nc = h.siz.comps.len
  # MCT flag must agree across components in v1.
  for c in 1..<nc:
    if tile.comps[c].style.mct != tile.comps[0].style.mct:
      return err[seq[TilePlane]](unsupportedError(ukGenericFeature,
        "j2k: mixed MCT"))
  # concatenate this tile's parts in TPsot order
  let g = tileGrid(h.siz)
  let ti = ty * g.nx + tx
  var order: seq[J2kTilePart] = @[]
  for p in h.parts:
    if p.isot == ti: order.add(p)
  if order.len == 0:
    return err[seq[TilePlane]](decodingError("j2k: missing tile"))
  for i in 0..<order.len:
    for j in i+1..<order.len:
      if order[j].tpsot < order[i].tpsot:
        let t = order[i]; order[i] = order[j]; order[j] = t
  var tileBuf: seq[uint8] = @[]
  for p in order:
    for i in p.dataStart..<p.dataEnd: tileBuf.add(data[i])
  # tile-local POC (opj places POC in tile-part headers) overrides main.
  var poc = h.poc
  var hasTilePoc = false
  for p in order:
    if p.pocPay.len > 0: hasTilePoc = true
  if hasTilePoc:
    poc = @[]
    for p in order:
      for pay in p.pocPay:
        let pr = parsePocPayload(pay, nc)
        if not pr.ok: return err[seq[TilePlane]](pr.err)
        poc.add(pr.value)
  # progression packet list
  var precCount: seq[seq[int]] = @[]
  for c in 0..<nc:
    var pc: seq[int] = @[]
    for r in 0..<tile.comps[c].res.len:
      pc.add(tile.comps[c].res[r].precNx * tile.comps[c].res[r].precNy)
    precCount.add(pc)
  let nres = tile.comps[0].res.len
  var packets: seq[PktCoord] = @[]
  if poc.len == 0:
    packets = iterPackets(h.cod.prog, h.cod.layers, nres, nc, precCount)
  else:
    packets = iterPacketsPoc(poc, h.cod.layers, nres, nc, precCount)
  var pos = 0
  var sop = 0
  for coord in packets:
    let style = tile.comps[coord.comp].style
    let pr = parsePacket(tileBuf, pos, tileBuf.len, coord, tile, sop,
      style)
    if not pr.ok: return err[seq[TilePlane]](decodingError("j2k: bad packet"))
    let bodyStart = pos
    var cur = bodyStart
    for f in pr.feeds:
      var st = tile.comps[coord.comp].res[coord.res].subs[f.sb].pkt[f.blk]
      let blk = tile.comps[coord.comp].res[coord.res].subs[f.sb].blocks[f.blk]
      if not st.hasWork:
        let bw = blk.x1 - blk.x0; let bh = blk.y1 - blk.y0
        if bw <= 0 or bh <= 0 or bw * bh > 4096:
          return err[seq[TilePlane]](decodingError("j2k: bad block dims"))
        let topBp = tile.comps[coord.comp].res[coord.res].subs[f.sb].geom.sigBp - 1 - st.zero
        if topBp < 0 or topBp > 64:
          return err[seq[TilePlane]](decodingError("j2k: bad top bitplane"))
        st.work = CbWork(
          plane: CbPlane(w: bw, h: bh, c: newSeq[CbCoeff](bw * bh)),
          orient: tile.comps[coord.comp].res[coord.res].subs[f.sb].geom.orient,
          topBp: topBp, maxPasses: topBp * 3 + 1, nextPass: 0, curBp: -2)
        st.hasWork = true
      for s in f.segs:
        if st.work.nextPass + s.passes > st.work.maxPasses:
          return err[seq[TilePlane]](decodingError("j2k: too many passes"))
        if s.length == 0:
          # Empty segments carry no bytes: opj omits symbol-less passes,
          # so there is nothing to decode — just advance the pass cursor.
          # (Encoder and decoder agree that no symbols are consumed here;
          # verified pixel-exact against opj on multi-layer files.)
          st.work.nextPass += s.passes
          tile.comps[coord.comp].res[coord.res].subs[f.sb].pkt[f.blk] = st
          continue
        if cur + s.length > bodyStart + pr.bodyLen or
            cur + s.length > tileBuf.len:
          return err[seq[TilePlane]](decodingError("j2k: body overrun"))
        if not decodeCbSegment(st.work,
            tileBuf.toOpenArray(cur, cur + s.length - 1), s.passes,
            style.selBypass, style.reset, style.termAll, style.vcausal,
            style.predictable, style.segSym, s.useRaw):
          return err[seq[TilePlane]](decodingError("j2k: Tier-1"))
        cur += s.length
      tile.comps[coord.comp].res[coord.res].subs[f.sb].pkt[f.blk] = st
    pos = bodyStart + pr.bodyLen
  if pos != tileBuf.len:
    return err[seq[TilePlane]](decodingError("j2k: trailing tile bytes"))
  # assemble subband buffers + inverse DWT per component
  var planes: seq[TilePlane] = @[]
  for c in 0..<nc:
    let tc2 = tile.comps[c]
    let Wc = tc2.geom.tx1 - tc2.geom.tx0
    let Hc = tc2.geom.ty1 - tc2.geom.ty0
    if Wc <= 0 or Hc <= 0:
      return err[seq[TilePlane]](decodingError("j2k: bad tile-comp size"))
    let D = tc2.style.dlevels
    # absolute node bounds per depth (for sizes + lifting phases)
    var ax0 = newSeq[int](D+1); var ay0 = newSeq[int](D+1)
    var ax1 = newSeq[int](D+1); var ay1 = newSeq[int](D+1)
    ax0[0] = tc2.geom.tx0; ay0[0] = tc2.geom.ty0
    ax1[0] = tc2.geom.tx1; ay1[0] = tc2.geom.ty1
    for k in 0..<D:
      ax0[k+1] = ceilDiv(ax0[k], 2); ay0[k+1] = ceilDiv(ay0[k], 2)
      ax1[k+1] = ceilDiv(ax1[k], 2); ay1[k+1] = ceilDiv(ay1[k], 2)
    let llb = fillBandBuf(tc2, 0, 0)
    var bands: seq[seq[BandBuf]] = @[]
    bands.add(@[])  # index 0 unused
    for r in 1..<tc2.res.len:
      if tc2.res[r].subs.len != 3:
        return err[seq[TilePlane]](decodingError("j2k: bad subbands"))
      bands.add(@[fillBandBuf(tc2, r, 0), fillBandBuf(tc2, r, 1),
        fillBandBuf(tc2, r, 2)])
    let rec = idwt53Tile(D, llb, bands, ax0, ay0, ax1, ay1)
    if not rec.ok:
      return err[seq[TilePlane]](decodingError("j2k: IDWT"))
    var buf = rec.buf
    if buf.len != Wc * Hc:
      return err[seq[TilePlane]](decodingError("j2k: IDWT size"))
    planes.add(TilePlane(x0: tc2.geom.tx0, y0: tc2.geom.ty0, w: Wc, h: Hc,
      d: move(buf)))
  # inverse MCT (RCT) on first three components
  if h.cod.mct and nc >= 3:
    let Wc = planes[0].w; let Hc = planes[0].h
    if planes[1].w != Wc or planes[2].w != Wc or planes[1].h != Hc or
        planes[2].h != Hc:
      return err[seq[TilePlane]](unsupportedError(ukGenericFeature,
        "j2k: MCT size mismatch"))
    for i in 0..<Wc*Hc:
      let y = planes[0].d[i]; let cb = planes[1].d[i]; let cr = planes[2].d[i]
      let g = y - ((cb + cr) shr 2)
      planes[0].d[i] = cr + g
      planes[1].d[i] = g
      planes[2].d[i] = cb + g
  ok(planes)

proc decodeJ2kRaw*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## Raw codestream decode: lossless 5/3 + RCT, 1-4 comps, 8/16-bit,
  ## single/multi tile, all 5 progressions + POC (main or tile-part
  ## headers), SOP/EPH, bypass. 9/7, HT/mixed, subsampling, palettes,
  ## packed headers and tile-part coding overrides are clean Unsupported
  ## (follow-up phases).
  let h0 = parseCodestream(data)
  if not h0.ok: return err[DynamicImage](h0.err)
  var h = h0.value
  if h.cod.ht or h.cod.mixed:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "j2k: HT codeblocks (next phase)"))
  if h.cod.trans != 1:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "j2k: irreversible 9/7 (next phase)"))
  if h.ppm.len > 0 or h.ppt.len > 0:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "j2k: packed packet headers"))
  for p in h.parts:
    if p.hasPpt:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "j2k: packed packet headers"))
    if p.hasCodingOverride:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "j2k: tile-part coding overrides"))
  let nc = h.siz.comps.len
  if nc < 1 or nc > 4:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "j2k: component count"))
  # v1: no subsampling (all comps full-res).
  for c in 0..<nc:
    if h.siz.comps[c].xr != 1 or h.siz.comps[c].yr != 1:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "j2k: subsampled components"))
    if h.siz.comps[c].prec < 1 or h.siz.comps[c].prec > 16:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "j2k: precision"))
  let p0 = h.siz.comps[0].prec
  let s0 = h.siz.comps[0].signed
  for c in 1..<nc:
    if h.siz.comps[c].prec != p0 or h.siz.comps[c].signed != s0:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "j2k: mixed precision"))
  let (cw, chh) = frameSize(h.siz)
  if cw <= 0 or chh <= 0:
    return err[DynamicImage](decodingError("j2k: bad canvas"))
  let g = tileGrid(h.siz)
  # canvas per component (int64 working samples)
  var canvas: seq[seq[int64]] = @[]
  for c in 0..<nc:
    canvas.add(newSeq[int64](cw * chh))
  for ty in 0..<g.ny:
    for tx in 0..<g.nx:
      let tr = decodeTile(data, h, tx, ty)
      if not tr.ok: return err[DynamicImage](tr.err)
      for c in 0..<nc:
        let tp = tr.value[c]
        for dy in 0..<tp.h:
          for dx in 0..<tp.w:
            canvas[c][(tp.y0 + dy) * cw + (tp.x0 + dx)] =
              tp.d[dy * tp.w + dx]
  # shift + clip + map to DynamicImage
  let big = p0 > 8
  if nc == 1:
    if big:
      var px = newSeq[Luma[uint16]](cw * chh)
      for i in 0..<cw*chh: px[i] = Luma[uint16](data: [clipU16(canvas[0][i], p0, s0)])
      return ok(DynamicImage(kind: dkLuma16,
        luma16: Gray16Image(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
    else:
      var px = newSeq[Luma[uint8]](cw * chh)
      for i in 0..<cw*chh: px[i] = Luma[uint8](data: [clipU8(canvas[0][i], p0, s0)])
      return ok(DynamicImage(kind: dkLuma8,
        luma8: GrayImage(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
  elif nc == 2:
    if big:
      var px = newSeq[LumaA[uint16]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = LumaA[uint16](data: [clipU16(canvas[0][i], p0, s0),
          clipU16(canvas[1][i], p0, s0)])
      return ok(DynamicImage(kind: dkLumaA16,
        lumaA16: GrayAlpha16Image(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
    else:
      var px = newSeq[LumaA[uint8]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = LumaA[uint8](data: [clipU8(canvas[0][i], p0, s0),
          clipU8(canvas[1][i], p0, s0)])
      return ok(DynamicImage(kind: dkLumaA8,
        lumaA8: GrayAlphaImage(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
  elif nc == 3:
    if big:
      var px = newSeq[Rgb[uint16]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = Rgb[uint16](data: [clipU16(canvas[0][i], p0, s0),
          clipU16(canvas[1][i], p0, s0), clipU16(canvas[2][i], p0, s0)])
      return ok(DynamicImage(kind: dkRgb16,
        rgb16: Rgb16Image(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
    else:
      var px = newSeq[Rgb[uint8]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = Rgb[uint8](data: [clipU8(canvas[0][i], p0, s0),
          clipU8(canvas[1][i], p0, s0), clipU8(canvas[2][i], p0, s0)])
      return ok(DynamicImage(kind: dkRgb8,
        rgb8: RgbImage(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
  else:
    if big:
      var px = newSeq[Rgba[uint16]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = Rgba[uint16](data: [clipU16(canvas[0][i], p0, s0),
          clipU16(canvas[1][i], p0, s0), clipU16(canvas[2][i], p0, s0),
          clipU16(canvas[3][i], p0, s0)])
      return ok(DynamicImage(kind: dkRgba16,
        rgba16: Rgba16Image(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))
    else:
      var px = newSeq[Rgba[uint8]](cw * chh)
      for i in 0..<cw*chh:
        px[i] = Rgba[uint8](data: [clipU8(canvas[0][i], p0, s0),
          clipU8(canvas[1][i], p0, s0), clipU8(canvas[2][i], p0, s0),
          clipU8(canvas[3][i], p0, s0)])
      return ok(DynamicImage(kind: dkRgba8,
        rgba8: RgbaImage(width: uint32(cw), height: uint32(chh),
          pixels: move(px))))

type Jp2ColorInfo = object
  w, h, nc: int
  prec: int
  enumerated: int
  alpha: int
  sycc: bool
  bpccPrec: seq[int]
  bpccSigned: seq[bool]

proc parseJp2h(pay: openArray[uint8]): ImageResult[Jp2ColorInfo] =
  var ci = Jp2ColorInfo(alpha: -1)
  var pos = 0
  var haveIhdr = false
  while pos + 8 <= pay.len:
    var ln = int((uint32(pay[pos]) shl 24) or (uint32(pay[pos+1]) shl 16) or
      (uint32(pay[pos+2]) shl 8) or uint32(pay[pos+3]))
    var hdr = 8
    if ln == 1:
      if pos + 16 > pay.len:
        return err[Jp2ColorInfo](decodingError("jp2: bad XL sub-box"))
      ln = int((uint32(pay[pos+8]) shl 24) or (uint32(pay[pos+9]) shl 16) or
        (uint32(pay[pos+10]) shl 8) or uint32(pay[pos+11]))
      # high word must be zero for sane sizes
      if pay[pos+8] != 0 or pay[pos+9] != 0 or pay[pos+10] != 0 or
          pay[pos+11] != 0:
        discard
      hdr = 16
    if ln < hdr and ln != 0:
      return err[Jp2ColorInfo](decodingError("jp2: bad sub-box length"))
    var bEnd = pos + ln
    if ln == 0: bEnd = pay.len
    if bEnd > pay.len:
      return err[Jp2ColorInfo](decodingError("jp2: truncated sub-box"))
    let t0 = pay[pos+4]; let t1 = pay[pos+5]
    let t2 = pay[pos+6]; let t3 = pay[pos+7]
    let p = pos + hdr; let pl = bEnd - p
    if t0==uint8('i') and t1==uint8('h') and t2==uint8('d') and
        t3==uint8('r'):
      if haveIhdr:
        return err[Jp2ColorInfo](decodingError("jp2: duplicate ihdr"))
      if pl != 14:
        return err[Jp2ColorInfo](decodingError("jp2: bad ihdr"))
      ci.h = int((uint32(pay[p]) shl 24) or (uint32(pay[p+1]) shl 16) or
        (uint32(pay[p+2]) shl 8) or uint32(pay[p+3]))
      ci.w = int((uint32(pay[p+4]) shl 24) or (uint32(pay[p+5]) shl 16) or
        (uint32(pay[p+6]) shl 8) or uint32(pay[p+7]))
      ci.nc = (int(pay[p+8]) shl 8) or int(pay[p+9])
      let bpc = pay[p+10]
      if pay[p+11] != 7:
        return err[Jp2ColorInfo](decodingError("jp2: bad compression"))
      if ci.nc < 1 or ci.nc > 4 or ci.w <= 0 or ci.h <= 0:
        return err[Jp2ColorInfo](decodingError("jp2: bad ihdr dims"))
      if bpc == 0xFF:
        ci.prec = -1  # variable: bpcc required
      else:
        ci.prec = int(bpc and 0x7F) + 1
        ci.bpccSigned = @[]
        for _ in 0..<ci.nc: ci.bpccSigned.add((bpc and 0x80) != 0)
      haveIhdr = true
    elif t0==uint8('b') and t1==uint8('p') and t2==uint8('c') and
        t3==uint8('c'):
      if not haveIhdr:
        return err[Jp2ColorInfo](decodingError("jp2: bpcc before ihdr"))
      if pl != ci.nc:
        return err[Jp2ColorInfo](decodingError("jp2: bad bpcc"))
      ci.prec = -1
      ci.bpccPrec = @[]; ci.bpccSigned = @[]
      for i in 0..<pl:
        ci.bpccPrec.add(int(pay[p+i] and 0x7F) + 1)
        ci.bpccSigned.add((pay[p+i] and 0x80) != 0)
    elif t0==uint8('c') and t1==uint8('o') and t2==uint8('l') and
        t3==uint8('r'):
      if pl < 3:
        return err[Jp2ColorInfo](decodingError("jp2: bad colr"))
      let meth = pay[p]
      if meth == 1:
        if pl != 7:
          return err[Jp2ColorInfo](decodingError("jp2: bad enum colr"))
        ci.enumerated = int((uint32(pay[p+3]) shl 24) or
          (uint32(pay[p+4]) shl 16) or (uint32(pay[p+5]) shl 8) or
          uint32(pay[p+6]))
      elif meth == 2 or meth == 3:
        return err[Jp2ColorInfo](unsupportedError(ukColor,
          "jp2: ICC profile"))
      else:
        return err[Jp2ColorInfo](decodingError("jp2: bad colr meth"))
    elif t0==uint8('p') and t1==uint8('c') and t2==uint8('l') and
        t3==uint8('r'):
      return err[Jp2ColorInfo](unsupportedError(ukGenericFeature,
        "jp2: palette"))
    elif t0==uint8('c') and t1==uint8('m') and t2==uint8('a') and
        t3==uint8('p'):
      return err[Jp2ColorInfo](unsupportedError(ukGenericFeature,
        "jp2: palette mapping"))
    elif t0==uint8('c') and t1==uint8('d') and t2==uint8('e') and
        t3==uint8('f'):
      if pl < 2:
        return err[Jp2ColorInfo](decodingError("jp2: bad cdef"))
      let n = (int(pay[p]) shl 8) or int(pay[p+1])
      if pl != 2 + 6 * n or n > ci.nc + 4:
        return err[Jp2ColorInfo](decodingError("jp2: bad cdef"))
      for i in 0..<n:
        let cn = (int(pay[p+2+6*i]) shl 8) or int(pay[p+3+6*i])
        let typ = (int(pay[p+4+6*i]) shl 8) or int(pay[p+5+6*i])
        let assoc = (int(pay[p+6+6*i]) shl 8) or int(pay[p+7+6*i])
        if cn >= ci.nc + 4:
          return err[Jp2ColorInfo](decodingError("jp2: bad cdef channel"))
        if (typ == 1 or typ == 2) and assoc == 0 and cn < ci.nc and
            ci.alpha < 0:
          ci.alpha = cn
    elif t0==uint8('r') and t1==uint8('e') and t2==uint8('s'):
      discard # resolution boxes: informational in v1
    else:
      discard # unknown sub-box: lenient skip
    if ln == 0: break
    pos = bEnd
  if not haveIhdr:
    return err[Jp2ColorInfo](decodingError("jp2: missing ihdr"))
  if ci.prec == -1 and ci.bpccPrec.len == 0:
    return err[Jp2ColorInfo](decodingError("jp2: variable bitdepth w/o bpcc"))
  if ci.enumerated == 0:
    return err[Jp2ColorInfo](decodingError("jp2: missing colr"))
  ci.sycc = ci.enumerated == 18
  ok(ci)

proc syccToRgb(v: DynamicImage, prec: int): ImageResult[DynamicImage] =
  ## JP2 enumerated sYCC (18) to sRGB. Offsets live in the P-bit domain;
  ## conversion is float + half-up round, then clip (no extra level shift:
  ## Y is already unsigned).
  let o = float(1 shl (prec - 1))
  let hi = float((1 shl prec) - 1)
  proc cv(x: float): uint16 = uint16(clamp(int(x + 0.5), 0, int(hi)))
  if v.kind == dkRgb8:
    let s = v.rgb8
    var px = newSeq[Rgb[uint8]](s.pixels.len)
    for i, p in s.pixels:
      let y = float(int(p.data[0])); let cb = float(int(p.data[1])) - o
      let cr = float(int(p.data[2])) - o
      px[i] = Rgb[uint8](data: [uint8(cv(y + 1.402 * cr)),
        uint8(cv(y - 0.344136 * cb - 0.714136 * cr)),
        uint8(cv(y + 1.772 * cb))])
    return ok(DynamicImage(kind: dkRgb8,
      rgb8: RgbImage(width: s.width, height: s.height, pixels: move(px))))
  elif v.kind == dkRgb16:
    let s = v.rgb16
    var px = newSeq[Rgb[uint16]](s.pixels.len)
    for i, p in s.pixels:
      let y = float(int(p.data[0])); let cb = float(int(p.data[1])) - o
      let cr = float(int(p.data[2])) - o
      px[i] = Rgb[uint16](data: [cv(y + 1.402 * cr),
        cv(y - 0.344136 * cb - 0.714136 * cr), cv(y + 1.772 * cb)])
    return ok(DynamicImage(kind: dkRgb16,
      rgb16: Rgb16Image(width: s.width, height: s.height, pixels: move(px))))
  err[DynamicImage](decodingError("jp2: sYCC on non-RGB"))

proc reorderAlpha(v: DynamicImage, a: int): ImageResult[DynamicImage] =
  ## Move component a last (alpha). Supports 2/4-comp 8/16-bit.
  if v.kind == dkRgba8 and a >= 0 and a < 4:
    let s = v.rgba8
    var px = newSeq[Rgba[uint8]](s.pixels.len)
    for i, p in s.pixels:
      var d = [p.data[0], p.data[1], p.data[2], p.data[3]]
      let av = d[a]
      var o = 0
      for k in 0..3:
        if k != a: d[o] = p.data[k]; inc o
      d[3] = av
      px[i] = Rgba[uint8](data: d)
    return ok(DynamicImage(kind: dkRgba8,
      rgba8: RgbaImage(width: s.width, height: s.height, pixels: move(px))))
  if v.kind == dkRgba16 and a >= 0 and a < 4:
    let s = v.rgba16
    var px = newSeq[Rgba[uint16]](s.pixels.len)
    for i, p in s.pixels:
      let av = p.data[a]
      var d = p.data
      var o = 0
      for k in 0..3:
        if k != a: d[o] = p.data[k]; inc o
      d[3] = av
      px[i] = Rgba[uint16](data: d)
    return ok(DynamicImage(kind: dkRgba16,
      rgba16: Rgba16Image(width: s.width, height: s.height, pixels: move(px))))
  if v.kind == dkLumaA8 and a == 0:
    # alpha-first gray: swap to (gray, alpha)
    let s = v.lumaA8
    var px = newSeq[LumaA[uint8]](s.pixels.len)
    for i, p in s.pixels:
      px[i] = LumaA[uint8](data: [p.data[1], p.data[0]])
    return ok(DynamicImage(kind: dkLumaA8,
      lumaA8: GrayAlphaImage(width: s.width, height: s.height,
        pixels: move(px))))
  if v.kind == dkLumaA16 and a == 0:
    let s = v.lumaA16
    var px = newSeq[LumaA[uint16]](s.pixels.len)
    for i, p in s.pixels:
      px[i] = LumaA[uint16](data: [p.data[1], p.data[0]])
    return ok(DynamicImage(kind: dkLumaA16,
      lumaA16: GrayAlpha16Image(width: s.width, height: s.height,
        pixels: move(px))))
  err[DynamicImage](decodingError("jp2: bad alpha channel"))

proc parseJp2(data: openArray[uint8]): ImageResult[tuple[ci: Jp2ColorInfo,
    off, ln: int]] =
  if data.len < 12:
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: too short"))
  if not (data[0]==0 and data[1]==0 and data[2]==0 and data[3]==12 and
      data[4]==uint8('j') and data[5]==uint8('P') and data[6]==uint8(' ') and
      data[7]==uint8(' ')):
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: bad signature"))
  if not (data[8]==13 and data[9]==10 and data[10]==0x87 and data[11]==10):
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: bad signature magic"))
  var pos = 12
  var seenFtyp = false
  var ci = Jp2ColorInfo(alpha: -1)
  var off = 0; var ln = 0
  var haveIhdr = false
  var haveJp2c = false
  while pos + 8 <= data.len:
    var bln = int(u32be(data, pos))
    var hdr = 8
    if bln == 1:
      if pos + 16 > data.len:
        return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: bad XL box"))
      let hi = int(u32be(data, pos + 8)); let lo = int(u32be(data, pos + 12))
      bln = hi * 4096 * 1048576 + lo  # hi shl 32
      hdr = 16
    if bln < hdr and bln != 0:
      return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: bad box length"))
    var boxEnd = pos + bln
    if bln == 0: boxEnd = data.len
    if boxEnd > data.len:
      return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: truncated box"))
    let t0 = data[pos+4]; let t1 = data[pos+5]
    let t2 = data[pos+6]; let t3 = data[pos+7]
    let pay = pos + hdr; let payLen = boxEnd - pay
    if t0==uint8('f') and t1==uint8('t') and t2==uint8('y') and t3==uint8('p'):
      seenFtyp = true
    elif t0==uint8('j') and t1==uint8('p') and t2==uint8('2') and
        t3==uint8('h'):
      if not seenFtyp:
        return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: jp2h before ftyp"))
      let cr = parseJp2h(data.toOpenArray(pay, boxEnd - 1))
      if not cr.ok: return err[tuple[ci: Jp2ColorInfo, off, ln: int]](cr.err)
      ci = cr.value
      haveIhdr = true
    elif t0==uint8('j') and t1==uint8('p') and t2==uint8('2') and
        t3==uint8('c'):
      if not seenFtyp:
        return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: jp2c before ftyp"))
      if not haveJp2c:
        off = pay; ln = payLen
        haveJp2c = true
    if bln == 0: break
    pos = boxEnd
  if not haveJp2c:
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: missing jp2c"))
  if not haveIhdr:
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](decodingError("jp2: missing jp2h"))
  if ci.nc < 1 or ci.nc > 4:
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](unsupportedError(ukGenericFeature, "jp2: comp count"))
  if ci.prec != -1 and (ci.prec < 1 or ci.prec > 16):
    return err[tuple[ci: Jp2ColorInfo, off, ln: int]](unsupportedError(ukGenericFeature, "jp2: precision"))
  ok((ci: ci, off: off, ln: ln))

proc decodeJp2*(data: openArray[uint8]): ImageResult[DynamicImage] =
  ## JP2 container decode: validate jp2h against the codestream SIZ
  ## (ihdr dims/comps, bpcc precisions), decode the first jp2c, apply
  ## color mapping (sYCC, alpha). Raw codestreams route straight through.
  if data.len >= 2 and data[0] == 0xFF and data[1] == 0x4F:
    return decodeJ2kRaw(data)
  let jc = parseJp2(data)
  if not jc.ok: return err[DynamicImage](jc.err)
  let j = jc.value.ci
  let coff = jc.value.off; let cln = jc.value.ln
  # validate container against codestream SIZ before decoding pixels
  let hh = parseCodestream(data.toOpenArray(coff, coff + cln - 1))
  if not hh.ok: return err[DynamicImage](hh.err)
  let (fw, fh) = frameSize(hh.value.siz)
  if fw != j.w or fh != j.h:
    return err[DynamicImage](decodingError("jp2: ihdr/SIZ size mismatch"))
  if hh.value.siz.comps.len != j.nc:
    return err[DynamicImage](decodingError("jp2: ihdr/SIZ comp mismatch"))
  for c in 0..<j.nc:
    let sc = hh.value.siz.comps[c]
    if j.prec == -1:
      if c >= j.bpccPrec.len:
        return err[DynamicImage](decodingError("jp2: bpcc short"))
      if sc.prec != j.bpccPrec[c] or sc.signed != j.bpccSigned[c]:
        return err[DynamicImage](decodingError("jp2: bpcc/SIZ mismatch"))
    else:
      if sc.prec != j.prec or sc.signed != j.bpccSigned[c]:
        return err[DynamicImage](decodingError("jp2: ihdr/SIZ bitdepth mismatch"))
  # enumerated colorspace gates (lenient gray, strict color)
  if j.nc == 1 and j.enumerated != 16 and j.enumerated != 17:
    return err[DynamicImage](decodingError("jp2: bad gray colorspace"))
  if j.nc >= 3 and j.enumerated != 16 and j.enumerated != 18:
    return err[DynamicImage](decodingError("jp2: bad colorspace"))
  let raw = decodeJ2kRaw(data.toOpenArray(coff, coff + cln - 1))
  if not raw.ok: return raw
  let v = raw.value
  let nc = case v.kind
    of dkLuma8, dkLuma16: 1
    of dkLumaA8, dkLumaA16: 2
    of dkRgb8, dkRgb16: 3
    of dkRgba8, dkRgba16: 4
    else: -1
  if nc != j.nc:
    return err[DynamicImage](decodingError("jp2: output comp mismatch"))
  if j.sycc:
    return syccToRgb(v, j.prec)
  if j.alpha >= 0 and j.alpha != nc - 1:
    return reorderAlpha(v, j.alpha)
  raw
