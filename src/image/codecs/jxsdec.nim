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
    var nxt = -1
    var i = dOff
    while i + 1 < buf.len:
      if buf[i] == 0xFF and (buf[i+1] == 0x20 or buf[i+1] == 0x11):
        nxt = i
        break
      inc i
    let dLen = if nxt < 0: buf.len - dOff else: nxt - dOff
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
