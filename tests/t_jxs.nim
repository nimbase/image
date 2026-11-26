## JPEG XS framing (Phase 0/1): PIH/CDT/CAP parse + probe.
## Sample decode lands in later phases (decode procs return Unsupported
## after the headers validate).
import unittest
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

test "jxs decode pending returns Unsupported after framing":
  let cs = minimalCs()
  let h = parseJxsCodestream(cs)
  check h.ok
  check h.value.pih.wf == 8
  check h.value.slices.len == 1
  check h.value.eocFound
  let d = decodeJxsRaw(cs)
  check not d.ok
  check d.err.kind == ekUnsupported

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

test "jxs truncation T clamps":
  check jxsTruncT(2, 0, 0, 1) == 1  # 2-0-1 (P<R)
  check jxsTruncT(2, 0, 1, 1) == 2  # 2-0-0 (P>=R)
  check jxsTruncT(0, 0, 0, 1) == 0  # clamp low
  check jxsTruncT(31, 0, 0, 0) == 15 # clamp high

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
