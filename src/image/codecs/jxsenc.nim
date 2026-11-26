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

proc jxsEncodeLossless*(w, h: int, planesU: seq[seq[uint16]], bd: uint8,
    cpih: uint8, multiSlice = false): ImageResult[seq[uint8]] =
  ## Lossless bare codestream. `planesU`: Nc planes of w*h samples in
  ## [0, 2^bd). Gray (Nc=1, Cpih=0) or RGB(A) (Nc=3/4, Cpih=1).
  let nc = planesU.len
  if w < 2 or h < 2 or w > 65535 or h > 65535:
    return err[seq[uint8]](decodingError("jxs enc: bad dimensions"))
  if bd < 8 or bd > 16:
    return err[seq[uint8]](decodingError("jxs enc: bit depth 8..16"))
  if nc < 1 or nc > 4:
    return err[seq[uint8]](decodingError("jxs enc: Nc 1..4"))
  if cpih == 1 and nc < 3:
    return err[seq[uint8]](decodingError("jxs enc: RCT needs Nc >= 3"))
  if cpih != 0 and cpih != 1:
    return err[seq[uint8]](decodingError("jxs enc: Cpih 0/1 only"))
  for p in planesU:
    if p.len != w * h:
      return err[seq[uint8]](decodingError("jxs enc: plane size"))
    for u in p:
      if u.uint32 >= (1'u32 shl bd.int):
        return err[seq[uint8]](decodingError("jxs enc: sample range"))
  let bw = bd
  # forward RCT for colour
  var planes = newSeq[seq[int]](nc)
  for i in 0..<nc:
    planes[i] = newSeq[int](w * h)
    for x in 0..<w*h: planes[i][x] = planesU[i][x].int
  # Annex G.3 inverse then F.4: level shift on the image samples FIRST
  # (a uniform shift does not commute with the RCT: Cb/Cr differences
  # would inherit a spurious bias), then the forward RCT, then the DWT.
  let dc = 1 shl (bw.int - 1)
  for i in 0..<nc:
    for x in 0..<w*h: planes[i][x] -= dc
  if cpih == 1:
    jxsForwardRct(planes)
  # forward cascade per component (NL 1/1)
  var picBands = newSeq[seq[seq[int]]](nc)
  for i in 0..<nc:
    let fR = jxsForwardCascade(w, h, 1, 1, planes[i])
    if not fR.ok: return err[seq[uint8]](fR.err)
    picBands[i] = fR.value
  # picture header + plan (WGT zeros; all bands exist full-res)
  var pih = JxsPih(lcod: 0, ppih: 0, plev: 0, wf: w.uint16,
    hf: h.uint16, cw: 0, hsl: 1, nc: nc.uint8, ng: 4, ss: 8, bw: bw,
    fq: 0, br: 4, fslc: 0, ppoc: 0, cpih: cpih, nlx: 1, nly: 1,
    lh: 0, rl: 0, qpih: 0, fs: 0, rm: 0)
  let nBeta = jxsNBeta(1, 1).int # 4
  var comps: seq[JxsComp] = @[]
  for _ in 0..<nc: comps.add(JxsComp(bitDepth: bd, sx: 1, sy: 1))
  var wgtZ = newSeq[uint8](2 * nBeta * nc)
  # max bitplane count sets Br (VLC bound min(2^Br-1,31))
  var maxM = 0
  for i in 0..<nc:
    for b in 0..<nBeta:
      for v in picBands[i][b]:
        let m = jxsBitLen(if v < 0: (-v).uint32 else: v.uint32)
        if m > maxM: maxM = m
  if maxM > 31:
    return err[seq[uint8]](decodingError("jxs enc: M exceeds 31"))
  var br: uint8 = 4
  if maxM > 15:
    br = jxsBitLen(maxM.uint32).uint8 # 2^Br-1 >= maxM
  pih.br = br
  let planR = jxsBuildPlan(pih, comps, wgtZ, 0)
  if not planR.ok: return err[seq[uint8]](planR.err)
  var plan = planR.value
  if multiSlice:
    # rebuild with Hsl=1 (one precinct row per slice)
    pih.hsl = 1
  else:
    pih.hsl = plan.npY.uint16
  let planR2 = jxsBuildPlan(pih, comps, wgtZ, 0)
  if not planR2.ok: return err[seq[uint8]](planR2.err)
  plan = planR2.value
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
  pihB.add(br) # Fq=0 | Br
  pihB.add(cpih) # Fslc/Ppoc/Cpih
  pihB.add(0x11) # NLx=1 NLy=1
  pihB.add(0x00) # Lh/Rl/Qpih/Fs/Rm
  seg(JxsMkrPih, pihB)
  var cdtB: seq[uint8] = @[]
  for _ in 0..<nc: cdtB.add(bd); cdtB.add(0x11)
  seg(JxsMkrCdt, cdtB)
  seg(JxsMkrWgt, wgtZ)
  for sp in plan.slices:
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
        let (dxL, dyL, txL, tyL) = jxsBetaLevels(loc.uint32, 1, 1)
        let (picBW, _) = jxsBandDims(w, h, dxL, dyL, txL, tyL)
        let powH = if dyL >= 1: 1 else: 1 shl (1 - dyL.int)
        let rowOff = py * powH
        let lines = (bg.l1 - bg.l0).int
        segLines[b] = lines
        var sg = newSeq[int](lines * bg.wpb.int)
        for li in 0..<lines:
          for x in 0..<bg.wpb.int:
            sg[li * bg.wpb.int + x] =
              picBands[i][loc][(rowOff + li) * picBW + x]
        segs[b] = move(sg)
      # M table per (band, group)
      var mTab = newSeq[seq[uint8]](prec.bands.len)
      for b, bg in prec.bands:
        if not bg.exists or bg.wpb == 0:
          mTab[b] = @[]
          continue
        let ncg = jxsNcg(bg.wpb, 4).int
        var mm = newSeq[uint8](ncg)
        for g in 0..<ncg:
          var mxv: uint32 = 0
          for k in 0..<4:
            let x = g * 4 + k
            if x < bg.wpb.int:
              for li in 0..<segLines[b]:
                let v = segs[b][li * bg.wpb.int + x]
                let a = if v < 0: (-v).uint32 else: v.uint32
                if a > mxv: mxv = a
          mm[g] = jxsBitLen(mxv).uint8
        mTab[b] = move(mm)
      # precinct body: reserve Lprc, then headers + packets
      let precStart = outP.len
      outP.add(@[0'u8, 0, 0]) # Lprc placeholder
      outP.add(0) # Q
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
          for g in 0..<mTab[bi].len:
            cntW.putUnary(mTab[bi][g].int) # theta=0 unary
        jxsAlign(cntW)
        var datW: JxsBitWriter
        for e in layout:
          let bi = e.band.int
          let bg = prec.bands[bi]
          let li = (e.line - bg.l0).int
          for g in 0..<mTab[bi].len:
            let m = mTab[bi][g].int
            if m > 0:
              let base = li * bg.wpb.int + g * 4
              # Table C.8: Fs=0 emits all Ng sign bits per group,
              # even past the band edge (0 there).
              for k in 0..<4:
                let x = g * 4 + k
                var sgn: uint8 = 0
                if x < bg.wpb.int and segs[bi][base + k] < 0: sgn = 1
                datW.putBit(sgn)
              for plane in countdown(m - 1, 0):
                for k in 0..<4:
                  let x = g * 4 + k
                  var bit: uint8 = 0
                  if x < bg.wpb.int:
                    let v = segs[bi][base + k]
                    let a = if v < 0: (-v).uint32 else: v.uint32
                    bit = uint8((a shr plane) and 1)
                  datW.putBit(bit)
        jxsAlign(datW)
        # short packet header: Dr + Ldat(15) + Lcnt(13) + Lsgn(11)
        if datW.buf.len >= (1 shl 15) or cntW.buf.len >= (1 shl 13):
          return err[seq[uint8]](decodingError("jxs enc: packet too big"))
        var hdr: JxsBitWriter
        hdr.putBits(0, 1)
        hdr.putBits(datW.buf.len.uint32, 15)
        hdr.putBits(cntW.buf.len.uint32, 13)
        hdr.putBits(0, 11)
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

proc encodeJxsGray8*(w, h: int, px: openArray[uint8],
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Lossless 8-bit gray still.
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, multiSlice)

proc encodeJxsGray16*(w, h: int, px: openArray[uint16], bd: uint8,
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Lossless gray still at `bd` bits (8..16).
  jxsEncodeLossless(w, h, @[@px], bd, 0, multiSlice)

proc encodeJxsRgb8*(w, h: int, rgb: openArray[uint8],
    multiSlice = false): ImageResult[seq[uint8]] =
  ## Lossless 8-bit RGB still (forward RCT).
  if rgb.len != w * h * 3:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var r = newSeq[uint16](w * h)
  var g = newSeq[uint16](w * h)
  var b = newSeq[uint16](w * h)
  for i in 0..<w*h:
    r[i] = rgb[3*i]
    g[i] = rgb[3*i+1]
    b[i] = rgb[3*i+2]
  jxsEncodeLossless(w, h, @[r, g, b], 8, 1, multiSlice)
