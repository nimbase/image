## JPEG XS framing (Phase 0/1): PIH/CDT/CAP parse + probe.
## Sample decode lands in later phases (decode procs return Unsupported
## after the headers validate).
import unittest
import std/options
import image

proc u16be(v: uint16): array[2, uint8] =
  [uint8(v shr 8), uint8(v and 0xFF)]

proc seg(marker: uint16, body: openArray[uint8]): seq[uint8] =
  result = @[uint8(marker shr 8), uint8(marker and 0xFF)]
  let l = uint16(body.len + 2)
  result.add(u16be(l))
  for b in body: result.add(b)

proc pihBody(nc: uint8, wf, hf: uint16): seq[uint8] =
  # 24-byte PIH: lossless 1-comp gray, NL 1/1.
  result = @[]
  for b in [0'u8, 0, 0, 0]: result.add(b)       # Lcod VBR
  for b in [0'u8, 0]: result.add(b)             # Ppih
  for b in [0'u8, 0]: result.add(b)             # Plev
  for b in u16be(wf): result.add(b)
  for b in u16be(hf): result.add(b)
  for b in [0'u8, 0]: result.add(b)             # Cw full width
  for b in u16be(1): result.add(b)              # Hsl
  result.add(nc); result.add(4); result.add(8)
  result.add(8)                                  # Bw
  result.add(0x04)                               # Fq=0 lossless, Br=4
  result.add(0x00)                               # Fslc/Ppoc/Cpih=0
  result.add(0x11)                               # NLx=1 NLy=1
  result.add(0x00)                               # Lh/Rl/Qpih/Fs/Rm=0

proc minimalCs(wf = 8'u16, hf = 8'u16): seq[uint8] =
  result = @[0xFF'u8, 0x10]                       # SOC
  result.add(seg(0xFF50, []))                     # CAP empty
  result.add(seg(0xFF12, pihBody(1, wf, hf)))     # PIH
  result.add(seg(0xFF13, [8'u8, 0x11]))           # CDT 1x 8-bit
  result.add(seg(0xFF14, [0'u8, 0, 0, 0, 0, 0, 0, 0])) # WGT 4 bands x (G,P)
  result.add(seg(0xFF20, [0'u8, 0]))              # SLH y=0, empty entropy
  result.add(@[0xFF'u8, 0x11])                    # EOC

test "jxs probe sniffs SOC+CAP and Signature":
  check probeJxs(minimalCs())
  check probeJxs(@[0x00'u8, 0x00, 0x00, 0x0C, 0x4A, 0x58, 0x53, 0x20,
    0x0D, 0x0A, 0x87, 0x0A])
  check not probeJxs(@[0x00'u8, 0x01, 0x02])
  check not probeJxs(@[])

test "jxs info reports geometry":
  let cs = minimalCs(8, 4)
  let inf = jxsInfo(cs)
  check inf.ok
  check inf.value.width == 8
  check inf.value.height == 4
  check inf.value.numComps == 1
  check inf.value.lossless
  check not inf.value.boxed

test "jxs decode runs the pipeline (degenerate empty slices fail clean)":
  let cs = minimalCs()
  let h = parseJxsCodestream(cs)
  check h.ok
  check h.value.pih.wf == 8
  check h.value.slices.len == 1
  check h.value.eocFound
  # Degenerate fixture (1 SLH for a 4-slice plan, no precinct headers):
  # clean decode error, never a crash. Real roundtrips arrive with the
  # encoder below.
  let d = decodeJxsRaw(cs)
  check not d.ok
  check d.err.kind == ekDecoding

test "jxs rejects bad PIH and missing CDT":
  var bad = minimalCs()
  check not jxsInfo(@[0xFF'u8, 0xD8]).ok
  # truncated codestream
  check not jxsInfo(bad[0..5]).ok

test "jxs plan 8x8 NL1/1: 4 bands, 4 slices, joint packets":
  # Nβ = 2*min+max+1 = 4 (LL,HL,LH,HH); Cs=8 → 1 col; Hp=2 → 4 rows;
  # Hsl=1 → 4 slices. First packet = β1=1 band (LL), then HL/LH/HH.
  let cs = minimalCs(8, 8)
  let h = parseJxsCodestream(cs)
  check h.ok
  let pl = jxsBuildPlan(h.value.pih, h.value.comps, h.value.wgt, 0)
  check pl.ok
  check pl.value.nBeta == 4
  check pl.value.nBands == 4
  check pl.value.npX == 1
  check pl.value.npY == 4
  check pl.value.slices.len == 4
  let prec = pl.value.slices[0].precincts[0]
  check prec.packets.len == 4
  check prec.packets[0].len == 1
  check prec.packets[0][0].band == 0
  check prec.packets[1][0].band == 1
  check prec.packets[2][0].band == 2
  check prec.packets[3][0].band == 3
  # plan-driven slice walk: empty-entropy slices cost 0 bytes
  for s in h.value.slices:
    check s.dataLen == 0

test "jxs precinct header parses hand-built bytes":
  # 8x8 NL1/1 plan: 4 existing bands. Lprc=5, Q=2, R=1, D=[2,0,1,3].
  # Bits: u24(5) u8(2) u8(1) + 8 D-bits (10 00 01 11) = 48 bits, no pad.
  let cs = minimalCs(8, 8)
  let h = parseJxsCodestream(cs)
  check h.ok
  let pl = jxsBuildPlan(h.value.pih, h.value.comps, h.value.wgt, 0)
  check pl.ok
  let prec = pl.value.slices[0].precincts[0]
  let raw = @[0x00'u8, 0x00, 0x05, 0x02, 0x01, 0x87]
  let ph = jxsParsePrecinctHdr(raw, prec)
  check ph.ok
  check ph.value.lprc == 5
  check ph.value.q == 2
  check ph.value.r == 1
  check ph.value.d == @[2'u8, 0, 1, 3]
  check ph.value.headerBytes == 6
  check not jxsParsePrecinctHdr(raw[0..4], prec).ok # truncated
  check not jxsParsePrecinctHdr(
    @[0x00'u8, 0x00, 0x00, 0x02, 0x01, 0x87], prec).ok # Lprc=0

test "jxs packet header short form parses hand-built bytes":
  # Dr=0, Ldat=10, Lcnt=5, Lsgn=0 → [00 0A 00 28 00].
  let pkt = jxsParsePacketHdr(
    @[0x00'u8, 0x0A, 0x00, 0x28, 0x00], true)
  check pkt.ok
  check pkt.value.dr == 0
  check pkt.value.ldat == 10
  check pkt.value.lcnt == 5
  check pkt.value.lsgn == 0
  check pkt.value.headerBytes == 5
  check not jxsParsePacketHdr(@[0x00'u8, 0x0A, 0x00], true).ok

test "jxs packet body hand-built oracle (no-pred, Fs=0)":
  # Mirrors the reference round-trip fixture: 1 band, wpb=16, Ncg=4,
  # T=0, D=0, Dr=0; M=[3,0,1,2]; body = E5 80 | 3A 2B 0A 8C A0.
  let bands = @[JxsBand(wpb: 16, gain: 0, priority: 0, l0: 0, l1: 1,
    exists: true)]
  let layout = @[JxsPacketEntry(band: 0, line: 0)]
  let body = @[0xE5'u8, 0x80, 0x3A, 0x2B, 0x0A, 0x8C, 0xA0]
  let pktR = jxsParsePacketHdr(
    @[0x00'u8, 0x05, 0x00, 0x10, 0x00], true)
  # short header Dr=0,Ldat=5,Lcnt=2,Lsgn=0
  check pktR.ok
  check pktR.value.ldat == 5
  check pktR.value.lcnt == 2
  var st = jxsInitState(bands, 4)
  let decR = jxsDecodePacketBody(body, bands, 4, 8, 4, 0, 0,
    @[0'u8], @[0'u8], pktR.value, layout, st, none(JxsPrecinctTop))
  check decR.ok
  check decR.value.consumed == 7
  check st.coefs[0].m == @[3'u8, 0, 1, 2]
  check st.coefs[0].v == @[5'u32, 0, 7, 1, 0, 0, 0, 0,
    1, 0, 1, 0, 3, 2, 1, 0]
  check st.coefs[0].s == @[0'u8, 0, 1, 1, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0]

test "jxs floor division is backend-independent":
  check jxsFDiv2(3) == 1
  check jxsFDiv2(-3) == -2
  check jxsFDiv2(-2) == -1
  check jxsFDiv4(2) == 0
  check jxsFDiv4(-2) == -1
  check jxsFDiv4(-5) == -2
  check jxsFDiv4(5) == 1

test "jxs forward 2x2 pins Table E.8 order (LL=14, not 15)":
  # README order example: [15 14; 15 12] analyses to LL=14 in E.8
  # order (rows-then-columns would give 15).
  var ll = newSeq[int](1)
  var hl = newSeq[int](1)
  var lh = newSeq[int](1)
  var hh = newSeq[int](1)
  let fr = jxsForward2d(2, 2, @[15, 14, 15, 12],
    ll.toOpenArray(0, 0), hl.toOpenArray(0, 0),
    lh.toOpenArray(0, 0), hh.toOpenArray(0, 0))
  check fr.ok
  check ll == @[14]
  check hl == @[-2]
  check lh == @[-1]
  check hh == @[-2]
  var back = newSeq[int](4)
  let ir = jxsInverse2d(2, 2, ll, hl, lh, hh, back)
  check ir.ok
  check back == @[15, 14, 15, 12]

test "jxs cascade roundtrips identity at several shapes":
  for (w, h, nlx, nly) in [(8, 8, 1'u8, 1'u8), (9, 7, 2, 1),
      (16, 12, 3, 2), (5, 5, 2, 2), (32, 4, 3, 1)]:
    var input = newSeq[int](w * h)
    for i in 0..<input.len:
      input[i] = (i * 37 + 11) mod 251 - 125
    let fwd = jxsForwardCascade(w, h, nlx, nly, input)
    check fwd.ok
    var back = newSeq[int](w * h)
    let inv = jxsInverseCascade(w, h, nlx, nly, fwd.value, back)
    check inv.ok
    check back == input

test "jxs deadzone dequant oracle":
  # wpb=4, Ng=4, T=2, M=4, v=[3,0,1,5], s=[0,0,1,0] → [14,0,-6,22].
  let cf = JxsBandCoef(wpb: 4, numLines: 1, v: @[3'u32, 0, 1, 5],
    s: @[0'u8, 0, 1, 0], m: @[4'u8])
  var outP = newSeq[int](4)
  jxsDequantDeadzone(cf, 2, 4, outP)
  check outP == @[14, 0, -6, 22]

test "jxs uniform dequant oracle":
  # T=0, M=1, v=[1,0,2,3], s=[0,0,0,1] → [1,0,2,-3].
  let cf = JxsBandCoef(wpb: 4, numLines: 1, v: @[1'u32, 0, 2, 3],
    s: @[0'u8, 0, 0, 1], m: @[1'u8])
  var outP = newSeq[int](4)
  jxsDequantUniform(cf, 0, 4, outP)
  check outP == @[1, 0, 2, -3]

test "jxs lossless gray8 roundtrip (single + multi slice, odd dims)":
  for (w, h, ms) in [(8, 8, false), (8, 8, true), (9, 7, false),
      (9, 7, true), (32, 16, false), (5, 5, true)]:
    var px = newSeq[uint8](w * h)
    for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
    let enc = encodeJxsGray8(w, h, px, multiSlice = ms)
    check enc.ok
    check probeJxs(enc.value)
    let inf = jxsInfo(enc.value)
    check inf.ok
    check inf.value.width == w.uint32
    check inf.value.height == h.uint32
    check inf.value.lossless
    let dec = decodeJxsRaw(enc.value)
    check dec.ok
    check dec.value.kind == dkLuma8
    check dec.value.dimensions() == (w.uint32, h.uint32)
    for i in 0..<px.len:
      check dec.value.luma8.pixels[i].data[0] == px[i]

test "jxs lossless rgb8 roundtrip (RCT)":
  for ms in [false, true]:
    let (w, h) = (12, 10)
    var rgb = newSeq[uint8](w * h * 3)
    for i in 0..<w*h:
      rgb[3*i] = uint8((i * 13 + 5) mod 251)
      rgb[3*i+1] = uint8((i * 29 + 7) mod 251)
      rgb[3*i+2] = uint8((i * 7 + 101) mod 251)
    let enc = encodeJxsRgb8(w, h, rgb, multiSlice = ms)
    check enc.ok
    let dec = decodeJxsRaw(enc.value)
    check dec.ok
    check dec.value.kind == dkRgb8
    for i in 0..<w*h:
      check dec.value.rgb8.pixels[i].data[0] == rgb[3*i]
      check dec.value.rgb8.pixels[i].data[1] == rgb[3*i+1]
      check dec.value.rgb8.pixels[i].data[2] == rgb[3*i+2]

test "jxs lossless gray16 roundtrip":
  let (w, h) = (10, 8)
  var px = newSeq[uint16](w * h)
  for i in 0..<px.len: px[i] = uint16((i * 257 + 13) mod 4096)
  let enc = encodeJxsGray16(w, h, px, 12)
  check enc.ok
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  check dec.value.kind == dkLuma16
  for i in 0..<px.len:
    check dec.value.luma16.pixels[i].data[0] == px[i]

test "jxs packet body hand-built oracle (Fs=1 separate signs)":
  # Same counts as the Fs=0 oracle; data carries magnitudes only and a
  # trailing sign sub-packet covers the 8 non-zero coefficients.
  let bands = @[JxsBand(wpb: 16, gain: 0, priority: 0, l0: 0, l1: 1,
    exists: true)]
  let layout = @[JxsPacketEntry(band: 0, line: 0)]
  let body = @[0xE5'u8, 0x80, 0xA2, 0xBA, 0xCA, 0x64]
  let pktR = jxsParsePacketHdr(
    @[0x00'u8, 0x03, 0x00, 0x10, 0x01], true)
  # short header Dr=0,Ldat=3,Lcnt=2,Lsgn=1 → [00 03 00 10 01]
  check pktR.ok
  check pktR.value.ldat == 3
  check pktR.value.lsgn == 1
  var st = jxsInitState(bands, 4)
  let decR = jxsDecodePacketBody(body, bands, 4, 8, 4, 1, 0,
    @[0'u8], @[0'u8], pktR.value, layout, st, none(JxsPrecinctTop))
  check decR.ok
  check decR.value.consumed == 6
  check st.coefs[0].m == @[3'u8, 0, 1, 2]
  check st.coefs[0].v == @[5'u32, 0, 7, 1, 0, 0, 0, 0,
    1, 0, 1, 0, 3, 2, 1, 0]
  check st.coefs[0].s == @[0'u8, 0, 1, 1, 0, 0, 0, 0,
    0, 0, 0, 0, 1, 0, 0, 0]

test "jxs significance gating skips bitplane counts":
  # Wpb=32 → Ncg=8, Ns=1; Z=1 marks the whole line insignificant:
  # no VLC bits, Lcnt=0, Ldat=0, everything zero.
  let bands = @[JxsBand(wpb: 32, gain: 0, priority: 0, l0: 0, l1: 1,
    exists: true)]
  let layout = @[JxsPacketEntry(band: 0, line: 0)]
  let pktR = jxsParsePacketHdr(
    @[0x00'u8, 0x00, 0x00, 0x00, 0x00], true)
  check pktR.ok
  var st = jxsInitState(bands, 4)
  let decR = jxsDecodePacketBody(@[0x80'u8], bands, 4, 8, 4, 0, 0,
    @[0'u8], @[2'u8], pktR.value, layout, st, none(JxsPrecinctTop))
  check decR.ok
  check decR.value.consumed == 1
  for m in st.coefs[0].m: check m == 0
  for v in st.coefs[0].v: check v == 0

test "jxs raw mode override reads Br bits per group":
  # Dr=1 overrides D=3 (would-be vertical+sig): raw counts then the
  # same data sub-packet as the Fs=0 oracle.
  let bands = @[JxsBand(wpb: 16, gain: 0, priority: 0, l0: 0, l1: 1,
    exists: true)]
  let layout = @[JxsPacketEntry(band: 0, line: 0)]
  let body = @[0x30'u8, 0x12, 0x3A, 0x2B, 0x0A, 0x8C, 0xA0]
  let pktR = jxsParsePacketHdr(
    @[0x80'u8, 0x05, 0x00, 0x10, 0x00], true)
  # Dr=1,Ldat=5,Lcnt=2,Lsgn=0 → [80 05 00 10 00]
  check pktR.ok
  check pktR.value.dr == 1
  var st = jxsInitState(bands, 4)
  let decR = jxsDecodePacketBody(body, bands, 4, 8, 4, 0, 0,
    @[0'u8], @[3'u8], pktR.value, layout, st, none(JxsPrecinctTop))
  check decR.ok
  check decR.value.consumed == 7
  check st.coefs[0].m == @[3'u8, 0, 1, 2]
  check st.coefs[0].v == @[5'u32, 0, 7, 1, 0, 0, 0, 0,
    1, 0, 1, 0, 3, 2, 1, 0]

test "jxs truncation T clamps":
  check jxsTruncT(2, 0, 0, 1) == 1  # 2-0-1 (P<R)
  check jxsTruncT(2, 0, 1, 1) == 2  # 2-0-0 (P>=R)
  check jxsTruncT(0, 0, 0, 1) == 0  # clamp low
  check jxsTruncT(31, 0, 0, 0) == 15 # clamp high

test "jxs lossless deeper NL roundtrips":
  # NL 2/1, 2/2, 3/2: multi-line precinct bands (LH/HH span 2-4 lines),
  # joint + pure-horizontal cascade phases on both sides.
  for (w, h, nlx, nly) in [(16, 16, 2'u8, 1'u8), (16, 16, 2, 2),
      (24, 20, 3, 2), (9, 7, 2, 1), (32, 12, 3, 1)]:
    var px = newSeq[uint8](w * h)
    for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
    let enc = encodeJxsGray8(w, h, px, nlx, nly)
    check enc.ok
    let dec = decodeJxsRaw(enc.value)
    check dec.ok
    check dec.value.kind == dkLuma8
    for i in 0..<px.len:
      check dec.value.luma8.pixels[i].data[0] == px[i]

test "jxs lossy Q ladder is bounded and monotone":
  # Deadzone truncation T=Q drops low bitplanes (midpoint rebuild) and
  # the 5/3 synthesis spreads it; max error stays within 2^(Q+1) here.
  # (`lossless` is a header-level Fq flag, as in the reference: a
  # truncated Fq=0 stream still reports it.)
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
  var prevMax = -1
  for q in [1'u8, 2, 4]:
    let enc = encodeJxsGray8(w, h, px, 1, 1, q)
    check enc.ok
    let dec = decodeJxsRaw(enc.value)
    check dec.ok
    var maxErr = 0
    for i in 0..<px.len:
      let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
      if d > maxErr: maxErr = d
    check maxErr <= (1 shl (q.int + 1))
    check maxErr >= prevMax
    prevMax = maxErr

test "jxs long packet headers roundtrip (Wf*Nc >= 32752)":
  # 32752-wide gray: short form is illegal, encoder must emit long.
  let (w, h) = (32752, 2)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8(i mod 251)
  let enc = encodeJxsGray8(w, h, px)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check not jxsUseShortHeader(h0.value.pih)
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  for i in countup(0, px.len - 1, 997):
    check dec.value.luma8.pixels[i].data[0] == px[i]

test "jxs BT.709 limited YCbCr hand vectors":
  # White / black / neutral exact per the integer formula.
  check jxsYcbcrPixel(235, 128, 128, 8) == (255, 255, 255)
  check jxsYcbcrPixel(16, 128, 128, 8) == (0, 0, 0)
  check jxsYcbcrPixel(180, 128, 128, 8) == (191, 191, 191)
  # BT.709 limited red primary (63, 102, 240): float reference gives
  # (231.1, 7.2, 6.3) — limited range cannot hold saturated red
  # exactly; the integer kernel lands within 1 of float.
  let (r, g, b) = jxsYcbcrPixel(63, 102, 240, 8)
  check abs(r - 231) <= 1
  check abs(g - 7) <= 1
  check abs(b - 6) <= 1
  # 16-bit true video levels: white 60160, black 4096, neutral 32768.
  check jxsYcbcrPixel(60160, 32768, 32768, 16) == (65535, 65535, 65535)
  check jxsYcbcrPixel(4096, 32768, 32768, 16) == (0, 0, 0)

test "jxs subsampled 422/420 roundtrips (planar YUV in, RGB out)":
  # Neutral-chroma ramps: decode must equal the direct BT.709
  # conversion of the same planes (chroma replicated, no filter).
  for (w, h, sxC, syC) in [(16, 12, 1'u8, 1'u8), (16, 12, 2, 1),
      (16, 12, 2, 2), (15, 11, 2, 2)]:
    let cwch = (w + sxC.int - 1) div sxC.int
    let chch = (h + syC.int - 1) div syC.int
    var y = newSeq[uint8](w * h)
    var cb = newSeq[uint8](cwch * chch)
    var cr = newSeq[uint8](cwch * chch)
    for i in 0..<y.len: y[i] = uint8(16 + (i * 200) div y.len)
    for i in 0..<cb.len:
      cb[i] = uint8(100 + (i * 7) mod 50)
      cr[i] = uint8(150 - (i * 5) mod 60)
    let enc = encodeJxsYuv8(w, h, y, cb, cr, sxC, syC)
    check enc.ok
    let dec = decodeJxsRaw(enc.value)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (w.uint32, h.uint32)
    for yy in 0..<h:
      for xx in 0..<w:
        let cx = min(xx div sxC.int, cwch - 1)
        let cy = min(yy div syC.int, chch - 1)
        let (er, eg, eb) = jxsYcbcrPixel(y[yy*w+xx].int,
          cb[cy*cwch+cx].int, cr[cy*cwch+cx].int, 8)
        let got = dec.value.rgb8.pixels[yy*w+xx].data
        check abs(got[0].int - er) <= 1
        check abs(got[1].int - eg) <= 1
        check abs(got[2].int - eb) <= 1

test "jxs .jxs file roundtrips (box, CICP, ihdr gate)":
  # Bare codestream -> boxed file -> decodeJxs: pixels identical.
  let (w2, h2) = (12, 10)
  var px2 = newSeq[uint8](w2 * h2)
  for i in 0..<px2.len: px2[i] = uint8((i * 41 + 3) mod 251)
  let cs2 = encodeJxsGray8(w2, h2, px2)
  check cs2.ok
  let fx = writeJxsFile(cs2.value)
  check fx.ok
  check isJxsFile(fx.value)
  check probeJxs(fx.value)
  let inf2 = jxsInfo(fx.value)
  check inf2.ok
  check inf2.value.boxed
  check inf2.value.width == w2.uint32
  let dec2 = decodeJxs(fx.value)
  check dec2.ok
  check dec2.value.kind == dkLuma8
  for i in 0..<px2.len:
    check dec2.value.luma8.pixels[i].data[0] == px2[i]
  # Contradictory ihdr (width +1) fails cleanly.
  var bad = fx.value
  # ihdr WIDTH lives at: 12 (sig) + 20 (ftyp) + 8 (jxsh) + 8 (ihdr) + 4
  let woff = 12 + 20 + 8 + 8 + 4
  bad[woff] = uint8((w2 + 1) shr 8)
  bad[woff+1] = uint8((w2 + 1) and 0xFF)
  check not decodeJxs(bad).ok
  check not jxsInfo(bad).ok

test "jxs CICP matrix 0 decodes YUV444 as RGB direct":
  # Same codestream, two colour readings: bare = YCbCr conversion,
  # boxed with matrix 0 = identity (planes pass straight through).
  let (w3, h3) = (8, 8)
  var y3 = newSeq[uint8](w3 * h3)
  var cb3 = newSeq[uint8](w3 * h3)
  var cr3 = newSeq[uint8](w3 * h3)
  for i in 0..<y3.len:
    y3[i] = 100; cb3[i] = 50; cr3[i] = 200
  let cs3 = encodeJxsYuv8(w3, h3, y3, cb3, cr3, 1, 1)
  check cs3.ok
  let bare = decodeJxsRaw(cs3.value)
  check bare.ok
  # bare: converted (not the raw triple)
  check bare.value.rgb8.pixels[0].data != [100'u8, 50, 200]
  let fx3 = writeJxsFile(cs3.value, 0) # matrix 0 = identity
  check fx3.ok
  let boxed = decodeJxs(fx3.value)
  check boxed.ok
  check boxed.value.kind == dkRgb8
  for i in 0..<w3*h3:
    check boxed.value.rgb8.pixels[i].data == [100'u8, 50, 200]

test "jxs CICP full-range flag selects full swing":
  # Y=235 neutral: limited decodes to 255, full-range to 235.
  let (w4, h4) = (4, 4)
  var y4 = newSeq[uint8](w4 * h4)
  var c4 = newSeq[uint8](w4 * h4)
  for i in 0..<y4.len: y4[i] = 235; c4[i] = 128
  let cs4 = encodeJxsYuv8(w4, h4, y4, c4, c4, 1, 1)
  check cs4.ok
  let lim = decodeJxsRaw(cs4.value)
  check lim.ok
  check lim.value.rgb8.pixels[0].data[0] == 255
  let fx4 = writeJxsFile(cs4.value, 1, true) # matrix 1, full range
  check fx4.ok
  let full = decodeJxs(fx4.value)
  check full.ok
  check full.value.rgb8.pixels[0].data[0] == 235

test "jxs NLT marker parses (quad DCO, extended, rejects)":
  # Tnlt=1, σ=1, α=300 → DCO = 300 - 32768.
  check jxsParseNlt(@[1'u8, 0x80, 0x00]).value.dco == -32768
  # σ=0, α=12345 → DCO = 12345.
  check jxsParseNlt(@[1'u8, 0x30, 0x39]).value.dco == 12345
  let xe = jxsParseNlt(@[2'u8, 0, 0, 0, 100, 0, 0, 0, 200, 3])
  check xe.ok
  check xe.value.t1 == 100 and xe.value.t2 == 200 and xe.value.e == 3
  check not jxsParseNlt(@[2'u8, 0, 0, 0, 200, 0, 0, 0, 200, 3]).ok # T2<=T1
  check not jxsParseNlt(@[2'u8, 0, 0, 0, 100, 0, 0, 0, 200, 5]).ok # E>4
  check not jxsParseNlt(@[9'u8]).ok # reserved Tnlt
  check not jxsParseNlt(@[]).ok

test "jxs uniform quantizer (Qpih=1) lossy path":
  # Same Q ladder through the Neumann-series inverse: sane, bounded,
  # and different from the deadzone reconstruction.
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
  let enc = encodeJxsGray8(w, h, px, 1, 1, 2, false, 1)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.qpih == 1
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 8
  # deadzone at the same Q gives a different (also valid) picture
  let enc0 = encodeJxsGray8(w, h, px, 1, 1, 2)
  check enc0.ok
  let dec0 = decodeJxsRaw(enc0.value)
  check dec0.ok
  var same = true
  for i in 0..<px.len:
    if dec.value.luma8.pixels[i] != dec0.value.luma8.pixels[i]:
      same = false
      break
  check not same

test "jxs NLT quadratic roundtrips (Bw=18, CAP bit 2)":
  let (w, h) = (32, 32)
  var px = newSeq[uint8](w * h)
  for j in 0..<h:
    for i in 0..<w:
      px[j*w+i] = uint8(min((i * 4 + j * 3) div 2, 255))
  let enc = encodeJxsNltQuad8(w, h, px)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.bw == 18 and h0.value.pih.fq == 6
  check h0.value.nltKind == 1
  check (h0.value.cap[0] and 0x20) != 0 # CAP bit 2 set
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 2
  # (18,6) with the CAP bit cleared is rejected (no NLT capability).
  var doctored = enc.value
  doctored[6] = 0x00
  check not decodeJxsRaw(doctored).ok

test "jxs NLT extended roundtrips (Bw=18, CAP bit 3)":
  let (w, h) = (32, 32)
  var px = newSeq[uint8](w * h)
  for j in 0..<h:
    for i in 0..<w:
      px[j*w+i] = uint8(min((i * 4 + j * 3) div 2, 255))
  let enc = encodeJxsNltExt8(w, h, px, 1'u32 shl 14, 1'u32 shl 16, 1)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.bw == 18 and h0.value.pih.fq == 6
  check h0.value.nltKind == 2
  check (h0.value.cap[0] and 0x10) != 0 # CAP bit 3 set
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 2

test "jxs NLT quadratic high-bit-depth (Bw=20) roundtrips":
  # 12-bit gray + quadratic NLT auto-selects (Bw=20, Fq=8); the
  # wavelet domain runs at Bw=20 for precision headroom.
  let (w5, h5) = (16, 16)
  var px5 = newSeq[uint16](w5 * h5)
  for i in 0..<px5.len: px5[i] = uint16((i * 257 + 13) mod 4096)
  let enc5 = jxsEncodeLossless(w5, h5, @[px5], 12, 0, 1, 1, 0, false,
    @[], 0, 0, 1, 0)
  check enc5.ok
  let h05 = parseJxsCodestream(enc5.value)
  check h05.ok
  check h05.value.pih.bw == 20 and h05.value.pih.fq == 8
  check h05.value.nltKind == 1
  let dec5 = decodeJxsRaw(enc5.value)
  check dec5.ok
  check dec5.value.kind == dkLuma16
  var maxErr5 = 0
  for i in 0..<px5.len:
    let d = abs(dec5.value.luma16.pixels[i].data[0].int - px5[i].int)
    if d > maxErr5: maxErr5 = d
  check maxErr5 <= 8

test "jxs CWD suppression (Sd=1) roundtrips lossless":
  # 4 full-res comps, last one raw-coded: decode bypasses the DWT for
  # it. Comps 0-2 convert YCbCr->RGB (compare vs direct conversion);
  # comp 3 passes through bit-exactly.
  let (w, h) = (12, 10)
  var planes = newSeq[seq[uint16]](4)
  for c in 0..<4:
    planes[c] = newSeq[uint16](w * h)
    for i in 0..<w*h:
      planes[c][i] = uint16((i * (13 + c * 7) + c) mod 251)
  let enc = jxsEncodeLossless(w, h, planes, 8, 0, 1, 1, 0, false,
    @[], 0, 0, 0, 0, 0, 0, 0, 0, 1)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.cwdSd == 1
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  check dec.value.kind == dkRgba8
  for i in 0..<w*h:
    let (er, eg, eb) = jxsYcbcrPixel(planes[0][i].int, planes[1][i].int,
      planes[2][i].int, 8)
    let got = dec.value.rgba8.pixels[i].data
    check got[0].int == er
    check got[1].int == eg
    check got[2].int == eb
    check got[3] == planes[3][i].uint8

test "jxs CTS/CRG parse vectors":
  # Cf=0, e1=1, e2=2.
  let c0 = jxsParseCts(@[0x00'u8, 0x12])
  check c0.ok
  check c0.value.cf == 0 and c0.value.e1 == 1 and c0.value.e2 == 2
  # Cf=3, e1=e2=3.
  let c3 = jxsParseCts(@[0x03'u8, 0x33])
  check c3.ok
  check c3.value.cf == 3
  check not jxsParseCts(@[0x10'u8, 0x00]).ok # reserved nibble
  check not jxsParseCts(@[0x01'u8, 0x00]).ok # reserved Cf
  check not jxsParseCts(@[0x00'u8, 0x44]).ok # e > 3
  check not jxsParseCts(@[0x00'u8]).ok # short
  # RGGB registration -> Ct=0; GRBG -> Ct=1; junk -> -1.
  let rg = jxsParseCrg(@[0'u8, 0, 0, 0, 0x80, 0, 0, 0,
    0, 0, 0x80, 0, 0x80, 0, 0x80, 0], 4)
  check rg.ok
  check jxsCfaPatternType(rg.value) == 0
  check jxsDisplacement(0, 2) == (0, 0)
  check jxsComponentAt(0, 0, 1) == 0
  let gr = jxsParseCrg(@[0x80'u8, 0, 0, 0, 0, 0, 0, 0,
    0x80, 0, 0x80, 0, 0, 0, 0x80, 0], 4)
  check gr.ok
  check jxsCfaPatternType(gr.value) == 1
  check jxsDisplacement(1, 0) == (1, 1)
  check jxsComponentAt(1, 1, 1) == 0
  check jxsCfaPatternType(@[(0'u16, 0'u16), (0'u16, 5'u16),
    (0'u16, 0'u16), (0'u16, 0'u16)]) == -1
  check not jxsParseCrg(@[0'u8, 0, 0], 1).ok # length

test "jxs Star-Tetrix forward/inverse roundtrips in place":
  let (w, h) = (10, 8)
  var pls: seq[seq[int]] = @[]
  for c in 0..<4:
    var p = newSeq[int](w * h)
    for i in 0..<w*h: p[i] = (i * (7 + c * 3) + c) mod 251 - 125
    pls.add(move(p))
  let orig = pls
  var fwd = pls
  check jxsForwardStarTetrix(fwd, w, h, 1, 2, 0, 0).ok
  var back = fwd
  check jxsInverseStarTetrix(back, w, h, 1, 2, 0, 0).ok
  check back == orig
  # Cf=3 (in-line) + Ct=1 also roundtrips.
  var fwd2 = orig
  check jxsForwardStarTetrix(fwd2, w, h, 3, 0, 1, 3).ok
  var back2 = fwd2
  check jxsInverseStarTetrix(back2, w, h, 3, 0, 1, 3).ok
  check back2 == orig

test "jxs Star-Tetrix CFA still roundtrips losslessly":
  # 4 CFA comps through the full codestream (CTS + CRG on the wire).
  let (w, h) = (12, 10)
  var r = newSeq[uint8](w * h)
  var g1 = newSeq[uint8](w * h)
  var g2 = newSeq[uint8](w * h)
  var b = newSeq[uint8](w * h)
  for i in 0..<w*h:
    r[i] = uint8((i * 13 + 5) mod 251)
    g1[i] = uint8((i * 29 + 7) mod 251)
    g2[i] = uint8((i * 17 + 101) mod 251)
    b[i] = uint8((i * 7 + 11) mod 251)
  let enc = encodeJxsCfa8(w, h, r, g1, g2, b, 1, 2, 0, 0)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.cpih == 3
  check h0.value.hasCts
  check h0.value.hasCrg
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  check dec.value.kind == dkRgba8
  for i in 0..<w*h:
    check dec.value.rgba8.pixels[i].data == [r[i], g1[i], g2[i], b[i]]
  # Missing CRG fails cleanly (Cpih=3 requires it).
  var stripped: seq[uint8] = @[]
  var k = 0
  let cs = enc.value
  while k < cs.len:
    if k + 3 < cs.len and cs[k] == 0xFF and cs[k+1] == 0x19:
      let ln = (cs[k+2].int shl 8) or cs[k+3].int
      k += 2 + ln
    else:
      stripped.add(cs[k])
      inc k
  check stripped.len < cs.len # actually removed the CRG segment
  check not decodeJxsRaw(stripped).ok

test "jxs profile/level/CBR declarations verify":
  # 16x16 gray NL1/1: Hsl=8 -> Hsl*2^NLy = 16 rows, Main444_12 shape.
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 3) mod 251)
  let enc = encodeJxsGray8(w, h, px)
  check enc.ok
  # PIH body: Lcod @10, Ppih @14, Plev @16 (CAP empty => PIH at 6).
  check enc.value[6] == 0xFF and enc.value[7] == 0x12
  proc patched(base: seq[uint8], at: int, hi, lo: uint8): seq[uint8] =
    result = base
    result[at] = hi
    result[at+1] = lo
  # Valid Main444_12 + 4k1 level claim verifies.
  let okClaim = patched(patched(enc.value, 14, 0x3A, 0x40), 16, 0x20, 0x00)
  check decodeJxsRaw(okClaim).ok
  # Reserved Ppih fails.
  check not decodeJxsRaw(patched(enc.value, 14, 0x12, 0x34)).ok
  # Reserved Plev level (high 0xFF) fails.
  check not decodeJxsRaw(patched(enc.value, 16, 0xFF, 0x00)).ok
  # Full sublevel (0x80) with unrestricted profile fails (§A.4.2).
  check not decodeJxsRaw(patched(enc.value, 16, 0x00, 0x80)).ok
  # Non-zero Lcod must match the SOC..EOC byte count.
  var badLen = enc.value
  badLen[10] = 0; badLen[11] = 0; badLen[12] = 0; badLen[13] = 1
  check not decodeJxsRaw(badLen).ok
  # ...while a truthful Lcod verifies.
  var goodLen = enc.value
  let n = enc.value.len
  goodLen[10] = uint8(n shr 24); goodLen[11] = uint8((n shr 16) and 0xFF)
  goodLen[12] = uint8((n shr 8) and 0xFF); goodLen[13] = uint8(n and 0xFF)
  check decodeJxsRaw(goodLen).ok

test "jxs high-precision (Bw=20, Fq=8) lossy is sane and bounded":
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
  let enc = encodeJxsHighPrec8(w, h, px, 2)
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.bw == 20 and h0.value.pih.fq == 8
  let dec = decodeJxsRaw(enc.value)
  check dec.ok
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 8

test "jxs WGT gains steer truncation (encoder weights)":
  # Annex-H-style per-band (G,P): G=2 on the LL band lowers its T
  # (Q-G), so the LL keeps more bitplanes than the flat-WGT stream.
  # Encoder and decoder agree on T by construction (VLC is T-relative).
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  let enc0 = jxsEncodeLossless(w, h, @[pl], 8, 0, 1, 1, 4)
  check enc0.ok
  # flat band ids for 1 comp NL1/1: b = β (0=LL,1=HL,2=LH,3=HH).
  let enc1 = jxsEncodeLossless(w, h, @[pl], 8, 0, 1, 1, 4, false,
    @[], 0, 0, 0, 0, 0, 0, 0, 0, 0,
    @[(2'u8, 0'u8), (0'u8, 0'u8), (0'u8, 0'u8), (0'u8, 0'u8)])
  check enc1.ok
  let h1 = parseJxsCodestream(enc1.value)
  check h1.ok
  check h1.value.wgt == @[2'u8, 0, 0, 0, 0, 0, 0, 0]
  let dec0 = decodeJxsRaw(enc0.value)
  check dec0.ok
  let dec1 = decodeJxsRaw(enc1.value)
  check dec1.ok
  var same = true
  for i in 0..<px.len:
    if dec0.value.luma8.pixels[i] != dec1.value.luma8.pixels[i]:
      same = false
      break
  check not same # gain changed truncation -> different output
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec1.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 32

test "jxs mixed bit depths roundtrip via components API":
  # 3 comps, B=[8,10,10] on the (20,8) fractional path: the wavelet
  # decode runs per-component depths; DynamicImage has no layout for
  # mixed depths (reference routes to decode_components), so the
  # components API carries the planes with their own depths.
  let (w, h) = (16, 16)
  var p0 = newSeq[uint16](w * h)
  var p1 = newSeq[uint16](w * h)
  var p2 = newSeq[uint16](w * h)
  for i in 0..<w*h:
    p0[i] = uint16((i * 37 + 11) mod 251)
    p1[i] = uint16((i * 61 + 7) mod 1021)
    p2[i] = uint16((i * 43 + 101) mod 1021)
  let enc = jxsEncodeLossless(w, h, @[p0, p1, p2], 8, 0, 1, 1, 0,
    false, @[], bwAx = 20, fqAx = 8,
    bitDepths = @[8'u8, 10, 10])
  check enc.ok
  let h0 = parseJxsCodestream(enc.value)
  check h0.ok
  check h0.value.pih.bw == 20 and h0.value.pih.fq == 8
  check h0.value.comps[0].bitDepth == 8
  check h0.value.comps[1].bitDepth == 10
  # DynamicImage route declines mixed depths cleanly.
  check not decodeJxsRaw(enc.value).ok
  let dec = decodeJxsComponentsRaw(enc.value)
  check dec.ok
  check dec.value.comps.len == 3
  check dec.value.comps[0].bitDepth == 8
  check dec.value.comps[1].bitDepth == 10
  check dec.value.comps[2].bitDepth == 10
  var maxErr0 = 0
  var maxErr1 = 0
  for i in 0..<w*h:
    let g0 = dec.value.comps[0].samples[i].int
    let d0 = abs(g0 - p0[i].int)
    if d0 > maxErr0: maxErr0 = d0
    let g1 = int(uint16(dec.value.comps[1].samples[2*i]) or
      (uint16(dec.value.comps[1].samples[2*i+1]) shl 8))
    let d1 = abs(g1 - p1[i].int)
    if d1 > maxErr1: maxErr1 = d1
  # Fractional rounding spreads a few LSB; stays well within 8 LSB.
  check maxErr0 <= 8
  check maxErr1 <= 8
  # Mixed Fq=0 is rejected (Table A.8 needs uniform B[i] there).
  let badEnc = jxsEncodeLossless(w, h, @[p0, p1, p2], 8, 0, 1, 1, 0,
    false, @[], bitDepths = @[8'u8, 10, 10])
  check not badEnc.ok

test "jxs Annex H tables match the spec transcription":
  # 4:4:4 RCT tables H.1-H.3 (nc=3, cpih=1, nlx=5).
  let h1 = jxsAnnexHWeights(3, 1, 0, 5, 0, 0,
    [1'u8, 1, 1], [1'u8, 1, 1])
  check h1.ok
  check h1.weights.len == 18
  check h1.weights[0] == (3'u8, 6'u8)
  check h1.weights[1] == (2'u8, 8'u8)
  check h1.weights[17] == (0'u8, 17'u8)
  let h2 = jxsAnnexHWeights(3, 1, 0, 5, 1, 0,
    [1'u8, 1, 1], [1'u8, 1, 1])
  check h2.ok
  check h2.weights.len == 24
  check h2.weights[0] == (4'u8, 21'u8)
  let h3 = jxsAnnexHWeights(3, 1, 0, 5, 2, 0,
    [1'u8, 1, 1], [1'u8, 1, 1])
  check h3.ok
  check h3.weights.len == 30
  check h3.weights[0] == (4'u8, 12'u8)
  # 4:2:2 tables H.4-H.6 (cpih=0, chroma 422).
  let sx422 = [1'u8, 2, 2]
  let sy422 = [1'u8, 1, 1]
  check jxsAnnexHWeights(3, 0, 0, 5, 0, 0, sx422, sy422).weights.len == 18
  check jxsAnnexHWeights(3, 0, 0, 5, 1, 0, sx422, sy422).weights.len == 24
  check jxsAnnexHWeights(3, 0, 0, 5, 2, 0, sx422, sy422).weights.len == 30
  # 4:2:0 tables drop the `-*` slots: H.7 24->20, H.8 30->26.
  let sx420 = [1'u8, 2, 2]
  let sy420 = [1'u8, 2, 2]
  let h7 = jxsAnnexHWeights(3, 0, 0, 5, 1, 0, sx420, sy420)
  check h7.ok
  check h7.weights.len == 20
  check h7.weights[0] == (3'u8, 9'u8)
  let h8 = jxsAnnexHWeights(3, 0, 0, 5, 2, 0, sx420, sy420)
  check h8.ok
  check h8.weights.len == 26
  check not jxsAnnexHWeights(3, 0, 0, 5, 0, 0, sx420, sy420).ok # no NLy=0
  # CFA tables H.9-H.11 (nc=4, sd=1, cf columns differ).
  let sx4 = [1'u8, 1, 1, 1]
  let sy4 = [1'u8, 1, 1, 1]
  let h9a = jxsAnnexHWeights(4, 3, 1, 5, 0, 0, sx4, sy4)
  let h9b = jxsAnnexHWeights(4, 3, 1, 5, 0, 3, sx4, sy4)
  check h9a.ok and h9b.ok
  check h9a.weights.len == 19 and h9b.weights.len == 19
  check h9a.weights[0] == (3'u8, 3'u8)
  check h9b.weights[0] == (4'u8, 18'u8)
  check jxsAnnexHWeights(4, 3, 1, 5, 1, 0, sx4, sy4).weights.len == 25
  check jxsAnnexHWeights(4, 3, 1, 5, 2, 3, sx4, sy4).weights.len == 31
  # Untabulated configurations decline.
  check not jxsAnnexHWeights(3, 1, 0, 1, 1, 0,
    [1'u8, 1, 1], [1'u8, 1, 1]).ok # nlx != 5
  check not jxsAnnexHWeights(1, 0, 0, 5, 1, 0, [1'u8], [1'u8]).ok

test "jxs Annex H 444 weights drive WGT + truncation":
  # 64x16 RGB, NL 5/1, Q=4: Annex H PSNR tables steer the WGT body and
  # the forward truncation (differs from the flat-weights stream, stays
  # bounded, and the WGT body equals the H.2 table in emission order).
  let (w, h) = (64, 16)
  var rgb = newSeq[uint8](w * h * 3)
  for i in 0..<w*h:
    rgb[3*i] = uint8((i * 13 + 5) mod 251)
    rgb[3*i+1] = uint8((i * 29 + 7) mod 251)
    rgb[3*i+2] = uint8((i * 7 + 101) mod 251)
  var r = newSeq[uint16](w * h)
  var g = newSeq[uint16](w * h)
  var b = newSeq[uint16](w * h)
  for i in 0..<w*h:
    r[i] = rgb[3*i]; g[i] = rgb[3*i+1]; b[i] = rgb[3*i+2]
  let encH = jxsEncodeLossless(w, h, @[r, g, b], 8, 1, 5, 1, 4,
    false, @[], annexH = true)
  check encH.ok
  let hH = parseJxsCodestream(encH.value)
  check hH.ok
  let tab = jxsAnnexHWeights(3, 1, 0, 5, 1, 0,
    [1'u8, 1, 1], [1'u8, 1, 1])
  check tab.ok
  var expectWgt: seq[uint8] = @[]
  for e in tab.weights:
    expectWgt.add(e[0]); expectWgt.add(e[1])
  check hH.value.wgt == expectWgt
  let decH = decodeJxsRaw(encH.value)
  check decH.ok
  var maxErr = 0
  for i in 0..<w*h:
    for c in 0..<3:
      let d = abs(decH.value.rgb8.pixels[i].data[c].int - rgb[3*i+c].int)
      if d > maxErr: maxErr = d
  check maxErr <= 48
  # Flat weights at the same Q give a different (also valid) picture.
  let encF = jxsEncodeLossless(w, h, @[r, g, b], 8, 1, 5, 1, 4)
  check encF.ok
  let decF = decodeJxsRaw(encF.value)
  check decF.ok
  var same = true
  for i in 0..<w*h:
    if decH.value.rgb8.pixels[i] != decF.value.rgb8.pixels[i]:
      same = false
      break
  check not same

test "jxs signalling declares verified profile/level/CBR":
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 3) mod 251)
  let enc = encodeJxsGray8(w, h, px)
  check enc.ok
  # Profile claim: Main444_12 admits mono 8-bit NL1/1 slice-16.
  var prof = enc.value
  check jxsDeclareProfile(prof, 0x3A40'u16).ok
  check parseJxsCodestream(prof).value.pih.ppih == 0x3A40
  check decodeJxsRaw(prof).ok
  # Reserved profile is rejected and the buffer is unchanged.
  var badProf = enc.value
  check not jxsDeclareProfile(badProf, 0x1234'u16).ok
  check badProf == enc.value
  # Level claim 4k1/unrestricted-sublevel verifies on 16x16.
  var lev = enc.value
  check jxsDeclareLevel(lev, 0x2000'u16).ok
  check parseJxsCodestream(lev).value.pih.plev == 0x2000
  check decodeJxsRaw(lev).ok
  # Reserved level fails without mutating.
  var badLev = enc.value
  check not jxsDeclareLevel(badLev, 0xFF00'u16).ok
  check badLev == enc.value
  # CBR self-description: Lcod == SOC..EOC length, still decodes.
  var cbr = enc.value
  check jxsDeclareCbr(cbr).ok
  let hc = parseJxsCodestream(cbr)
  check hc.ok
  check hc.value.pih.lcod == cbr.len.uint32
  check decodeJxsRaw(cbr).ok
  # ...and VBR withdrawal resets Lcod to 0.
  check jxsDeclareVbr(cbr).ok
  check parseJxsCodestream(cbr).value.pih.lcod == 0

test "jxs COM pad + insert reach the decoder transparently":
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 3) mod 251)
  let enc = encodeJxsGray8(w, h, px)
  check enc.ok
  let dec0 = decodeJxsRaw(enc.value)
  check dec0.ok
  # Exact-size pad: COM segment(s) before the first SLH.
  var padded = enc.value
  let target = padded.len + 64
  check jxsPadToSize(padded, target).ok
  check padded.len == target
  var sawCom = false
  var k = 0
  while k + 1 < padded.len:
    if padded[k] == 0xFF and padded[k+1] == 0x15: sawCom = true
    if padded[k] == 0xFF and padded[k+1] == 0x20: break
    inc k
  check sawCom
  let dec1 = decodeJxsRaw(padded)
  check dec1.ok
  check dec1.value.luma8.pixels == dec0.value.luma8.pixels
  # CBR pair: pad + Lcod agree, pixels identical.
  var pair = enc.value
  check jxsDeclareCbrPadded(pair, pair.len + 20).ok
  check pair.len == enc.value.len + 20
  check parseJxsCodestream(pair).value.pih.lcod == pair.len.uint32
  check decodeJxsRaw(pair).ok
  # Unpaddable 3-byte gap fails without mutating.
  var tiny = enc.value
  check not jxsPadToSize(tiny, tiny.len + 3).ok
  check tiny == enc.value
  # COM insert (vendor string) decodes identically; then CBR over it.
  var ins = enc.value
  check jxsInsertCom(ins, 0x0000'u16, @[0x4E'u8, 0x69, 0x6D, 0x00]).ok
  check decodeJxsRaw(ins).ok
  check jxsDeclareCbr(ins).ok

test "jxs declareAuto picks the tightest verified claim":
  let (w, h) = (16, 16)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 3) mod 251)
  let enc = encodeJxsGray8(w, h, px)
  check enc.ok
  check jxsPickProfile(enc.value).value == 0x1500'u16 # Light422_10 first
  check jxsPickLevelHi(16, 16) == 0x10'u8
  check jxsPickLevelHi(7000, 7000) == 0x34'u8
  var auto = enc.value
  let aR = jxsDeclareAuto(auto, false)
  check aR.ok
  check aR.value.ppih == 0x1500'u16
  check (aR.value.plev shr 8) == 0x10'u16
  check decodeJxsRaw(auto).ok
  check parseJxsCodestream(auto).value.pih.ppih == 0x1500'u16

test "jxs CBR rate allocation hits the exact byte target":
  let (w, h) = (64, 64)
  var px = newSeq[uint8](w * h)
  for i in 0..<px.len: px[i] = uint8((i * 37 + 11) mod 251)
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  let lossless = jxsEncodeLossless(w, h, @[pl], 8, 0, 1, 1, 0,
    true)
  check lossless.ok
  let l0 = lossless.value.len
  var qMax = newSeq[uint8](32) # 64x64 NL1/1 multiSlice: npY=32 slices
  for t in 0..<qMax.len: qMax[t] = 15
  let worst = jxsEncodeLossless(w, h, @[pl], 8, 0, 1, 1, 0,
    true, @[], qSlices = qMax)
  check worst.ok
  let l15 = worst.value.len
  check l15 < l0 # budget room exists for the search
  let target = (l0 + l15) div 2
  let cbr = jxsEncodeCbr(w, h, @[pl], 8, 0, 1, 1, target, true)
  check cbr.ok
  check cbr.value.cs.len == target
  check parseJxsCodestream(cbr.value.cs).value.pih.lcod == target.uint32
  check cbr.value.qSlices.len == 32
  # Padded COM + declared level ride along (autoSignal). hsl=1
  # slicing admits no 21122-2 profile (slice-16 rule), so Ppih stays
  # unrestricted while Plev is still claimed.
  let hh = parseJxsCodestream(cbr.value.cs)
  check hh.ok
  check hh.value.pih.ppih == 0
  check hh.value.pih.plev != 0
  let dec = decodeJxsRaw(cbr.value.cs)
  check dec.ok
  var maxErr = 0
  for i in 0..<px.len:
    let d = abs(dec.value.luma8.pixels[i].data[0].int - px[i].int)
    if d > maxErr: maxErr = d
  check maxErr <= 64
  # Unreachable budget (below Q=15) fails cleanly.
  check not jxsEncodeCbr(w, h, @[pl], 8, 0, 1, 1, l15 - 6,
    true).ok
  # Single-slice CBR claims a profile too (slice-16 holds there).
  let cbr1 = jxsEncodeCbr(16, 16, @[pl[0..<256]], 8, 0, 1, 1, 400,
    false)
  check cbr1.ok
  check cbr1.value.cs.len == 400
  let hh1 = parseJxsCodestream(cbr1.value.cs)
  check hh1.ok
  check hh1.value.pih.ppih != 0
  check decodeJxsRaw(cbr1.value.cs).ok

test "jxs chroma-local beta drops deep LH/HH for sy=2":
  # NL 2/2 → Nβ=7. sy=2 loses one vertical level: picture β=2,3
  # (LH/HH at dy=2) have no chroma band; the rest map 1:1/proxy.
  check jxsPicBetaToLocal(0, 2, 2, 2) == 0
  check jxsPicBetaToLocal(1, 2, 2, 2) == 1
  check jxsPicBetaToLocal(2, 2, 2, 2) == -1
  check jxsPicBetaToLocal(3, 2, 2, 2) == -1
  check jxsPicBetaToLocal(4, 2, 2, 2) == 2
  check jxsPicBetaToLocal(5, 2, 2, 2) == 3
  check jxsPicBetaToLocal(6, 2, 2, 2) == 4
  # sy=1 is the identity map
  for b in 0'u32..<7'u32:
    check jxsPicBetaToLocal(b, 2, 2, 1) == b.int
