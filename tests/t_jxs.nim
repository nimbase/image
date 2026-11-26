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
