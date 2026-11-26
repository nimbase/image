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
