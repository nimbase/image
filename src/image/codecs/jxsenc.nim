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
    cpih: uint8, nlx: uint8 = 1, nly: uint8 = 1, q: uint8 = 0,
    multiSlice = false,
    sampling: seq[(uint8, uint8)] = @[]): ImageResult[seq[uint8]] =
  ## Lossless (`q=0`) or lossy (`q=1..15`, precinct truncation) bare
  ## codestream. `planesU`: Nc planes at native sampling in [0, 2^bd);
  ## `sampling` (default all 1:1) gives per-component (sx, sy).
  ## Gray (Nc=1, Cpih=0), YCbCr (Nc=3/4, Cpih=0) or RGB(A) (Nc=3/4,
  ## Cpih=1, full-res).
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
      if u.uint32 >= (1'u32 shl bd.int):
        return err[seq[uint8]](decodingError("jxs enc: sample range"))
  let bw = bd
  # forward RCT for colour
  var planes = newSeq[seq[int]](nc)
  for i in 0..<nc:
    planes[i] = newSeq[int](cw[i] * ch[i])
    for x in 0..<cw[i]*ch[i]: planes[i][x] = planesU[i][x].int
  # Annex G.3 inverse then F.4: level shift on the image samples FIRST
  # (a uniform shift does not commute with the RCT: Cb/Cr differences
  # would inherit a spurious bias), then the forward RCT, then the DWT.
  let dc = 1 shl (bw.int - 1)
  for i in 0..<nc:
    for x in 0..<cw[i]*ch[i]: planes[i][x] -= dc
  if cpih == 1:
    jxsForwardRct(planes)
  # forward cascade per component at its effective depth
  var picBands = newSeq[seq[seq[int]]](nc)
  for i in 0..<nc:
    let lg = jxsLog2Sy(sy[i])
    if lg < 0:
      return err[seq[uint8]](decodingError("jxs enc: bad sampling"))
    let nlyI = satSub8(nly, lg.uint8)
    let fR = jxsForwardCascade(cw[i], ch[i], nlx, nlyI, planes[i])
    if not fR.ok: return err[seq[uint8]](fR.err)
    picBands[i] = fR.value
  # picture header + plan (WGT zeros; existing bands only)
  var pih = JxsPih(lcod: 0, ppih: 0, plev: 0, wf: w.uint16,
    hf: h.uint16, cw: 0, hsl: 1, nc: nc.uint8, ng: 4, ss: 8, bw: bw,
    fq: 0, br: 4, fslc: 0, ppoc: 0, cpih: cpih, nlx: nlx, nly: nly,
    lh: 0, rl: 0, qpih: 0, fs: 0, rm: 0)
  let nBeta = jxsNBeta(nlx, nly).int
  var comps: seq[JxsComp] = @[]
  for i in 0..<nc:
    comps.add(JxsComp(bitDepth: bd, sx: sx[i], sy: sy[i]))
  # count existing (β,i) slots for the WGT body (Annex A.4.11 skips
  # non-existent bands, same order the walker consumes)
  var nExist = 0
  for beta in 0..<nBeta:
    for i in 0..<nc:
      if jxsPicBetaToLocal(beta.uint32, nlx, nly, sy[i]) >= 0:
        inc nExist
  var wgtZ = newSeq[uint8](2 * nExist)
  # truncation is uniform T=q (G=P=R=0); M floor is T (lossy) or 0.
  let truncU = q
  # max emitted bitplane count sets Br (VLC bound min(2^Br-1,31))
  var maxM = 0
  for i in 0..<nc:
    for b in 0..<picBands[i].len:
      for v in picBands[i][b]:
        let m = jxsBitLen(if v < 0: (-v).uint32 else: v.uint32)
        let me = max(truncU.int, m)
        if me > maxM: maxM = me
  if maxM > 31:
    return err[seq[uint8]](decodingError("jxs enc: M exceeds 31"))
  var br: uint8 = 4
  if maxM > 15:
    br = jxsBitLen(maxM.uint32).uint8 # 2^Br-1 >= maxM
  pih.br = br
  let useShort = w * nc < 32752
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
  pihB.add((nlx shl 4) or nly) # NLx/NLy
  pihB.add(0x00) # Lh/Rl/Qpih/Fs/Rm
  seg(JxsMkrPih, pihB)
  var cdtB: seq[uint8] = @[]
  for i in 0..<nc:
    cdtB.add(bd)
    cdtB.add((sx[i] shl 4) or sy[i])
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
        let lgI = jxsLog2Sy(sy[i])
        if lgI < 0:
          return err[seq[uint8]](decodingError("jxs enc: bad sampling"))
        let nlyI = satSub8(nly, lgI.uint8)
        let (dxL, dyL, txL, tyL) = jxsBetaLevels(loc.uint32, nlx, nlyI)
        let (picBW, _) = jxsBandDims(cw[i], ch[i], dxL, dyL, txL, tyL)
        let powH =
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
      # M table per (band, line, group): emitted M floors at T (lossy:
      # dropping high planes is illegal, T drops low ones instead).
      var mTab = newSeq[seq[seq[uint8]]](prec.bands.len)
      for b, bg in prec.bands:
        if not bg.exists or bg.wpb == 0:
          mTab[b] = @[]
          continue
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
            mm[g] = max(truncU, jxsBitLen(mxv).uint8)
          ml[li] = move(mm)
        mTab[b] = move(ml)
      # precinct body: reserve Lprc, then headers + packets
      let precStart = outP.len
      outP.add(@[0'u8, 0, 0]) # Lprc placeholder
      outP.add(q) # Q
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
          # line index within this precinct's segment
          let lix = (e.line - prec.bands[bi].l0).int
          for g in 0..<mTab[bi][lix].len:
            cntW.putUnary(mTab[bi][lix][g].int - truncU.int) # theta=0
        jxsAlign(cntW)
        var datW: JxsBitWriter
        for e in layout:
          let bi = e.band.int
          let bg = prec.bands[bi]
          let li = (e.line - bg.l0).int
          for g in 0..<mTab[bi][li].len:
            let m = mTab[bi][li][g].int
            if m > truncU.int:
              let base = li * bg.wpb.int + g * 4
              # Table C.8: Fs=0 emits all Ng sign bits per group,
              # even past the band edge (0 there).
              for k in 0..<4:
                let x = g * 4 + k
                var sgn: uint8 = 0
                if x < bg.wpb.int and segs[bi][base + k] < 0: sgn = 1
                datW.putBit(sgn)
              for plane in countdown(m - 1, truncU.int):
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
    nly: uint8 = 1, q: uint8 = 0, multiSlice = false): ImageResult[seq[uint8]] =
  ## Gray still, 8-bit; `q=0` lossless, `q=1..15` lossy (precinct cut).
  if px.len != w * h:
    return err[seq[uint8]](decodingError("jxs enc: pixel count"))
  var pl = newSeq[uint16](w * h)
  for i in 0..<pl.len: pl[i] = px[i]
  jxsEncodeLossless(w, h, @[pl], 8, 0, nlx, nly, q, multiSlice)

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
  let bd = h.comps[0].bitDepth
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
  ih.add(bd - 1) # BPC: unsigned, (bpc & 0x7F)+1 = depth
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
