# DWAA/DWAB encode (lossy DCT; mirrors OpenEXRCore internal_dwa_encoder.h
# scalar paths but with the SSE2 forward-DCT association and hardcoded
# decimal constants, which the reference uses on x86-64).
# Included by openexr.nim (shares its scope).

proc dwaDctForward*(d: var array[64, float32]) =
  ## Forward 8x8 DCT, SSE2 association + decimal constants (dctForward8x8
  ## SSE2 path). Column-first via explicit transposes in the caller, exactly
  ## like the reference (two column passes with an in-place transpose
  ## between). Constants are the sasseembler's decimal literals, NOT
  ## cosf-computed (they differ by 1-2 ulp).
  const C4 = 0.70710678'f32
  const CN4 = -0.70710678'f32
  const C1H = 0.490392640'f32
  const C2H = 0.461939770'f32
  const C3H = 0.415734810'f32
  const C5H = 0.277785120'f32
  const C6H = 0.191341720'f32
  const C7H = 0.097545161'f32
  const H = 0.5'f32
  # row pass (1D DCT on rows; the caller transposes so this same routine
  # serves both passes, exactly like the reference's two iters)
  for row in 0..<8:
    let rp = row * 8
    let s0 = d[rp+0]; let s1 = d[rp+1]; let s2 = d[rp+2]; let s3 = d[rp+3]
    let s4 = d[rp+4]; let s5 = d[rp+5]; let s6 = d[rp+6]; let s7 = d[rp+7]
    let a0 = s0+s7; let a1 = s1+s2; let a2 = s1-s2; let a3 = s3+s4
    let a4 = s3-s4; let a5 = s5+s6; let a6 = s5-s6; let a7 = s0-s7
    var k0 = C4*(a0+a3)
    var k1 = C4*(a1+a5)
    d[rp+0] = (k0+k1)*H; d[rp+4] = (k0-k1)*H
    let rx0 = a2-a6
    let ry0 = a0-a3
    d[rp+2] = C6H*rx0 + C2H*ry0
    d[rp+6] = C6H*ry0 - C2H*rx0
    k0 = C4*(a1-a5)
    k1 = CN4*(a2+a6)
    let rx1 = a7-k0
    let ry1 = a4+k1
    d[rp+3] = C3H*rx1 - C5H*ry1
    d[rp+5] = C5H*rx1 + C3H*ry1
    let rx2 = a7+k0
    let ry2 = k1-a4
    d[rp+1] = C1H*rx2 - C7H*ry2
    d[rp+7] = C7H*rx2 + C1H*ry2

proc dwaTranspose8*(d: var array[64, float32]) =
  for y in 0..<8:
    for x in y+1..<8:
      let a = d[y*8+x]; d[y*8+x] = d[x*8+y]; d[x*8+y] = a

proc dwaCscFwd*(r, g, b: var array[64, float32]) =
  ## Forward 709 CSC (R'G'B' -> Y'CbCr, no offset). Scalar reference order.
  for i in 0..<64:
    let rr = r[i]; let gg = g[i]; let bb = b[i]
    r[i] = 0.2126'f32*rr + 0.7152'f32*gg + 0.0722'f32*bb
    g[i] = -0.1146'f32*rr - 0.3854'f32*gg + 0.5000'f32*bb
    b[i] = 0.5000'f32*rr - 0.4542'f32*gg - 0.0458'f32*bb

const dwaJpegQy* = [16, 11, 10, 16, 24, 40, 51, 61, 12, 12, 14, 19, 26, 58,
  60, 55, 14, 13, 16, 24, 40, 57, 69, 56, 14, 17, 22, 29, 51, 87, 80, 62,
  18, 22, 37, 56, 68, 109, 103, 77, 24, 35, 55, 64, 81, 104, 113, 92,
  49, 64, 78, 87, 103, 121, 120, 101, 72, 92, 95, 98, 112, 100, 103, 99]
const dwaJpegQc* = [17, 18, 24, 47, 99, 99, 99, 99, 18, 21, 26, 66, 99, 99,
  99, 99, 24, 26, 56, 99, 99, 99, 99, 99, 47, 66, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99,
  99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99, 99]

proc dwaCountSetBits*(x: uint16): int =
  ## popcount (matches __builtin_popcount).
  var v = uint32(x)
  v = v - (v shr 1 and 0x55555555'u32)
  v = (v and 0x33333333'u32) + ((v shr 2) and 0x33333333'u32)
  v = (v + (v shr 4)) and 0x0F0F0F0F'u32
  int((v * 0x01010101'u32) shr 24)

proc dwaCountLeadingZeros*(x: uint32): int =
  ## clz (matches __builtin_clz).
  if x == 0: return 32
  var n = 0
  var v = x
  if (v and 0xFFFF0000'u32) == 0: n += 16; v = v shl 16
  if (v and 0xFF000000'u32) == 0: n += 8; v = v shl 8
  if (v and 0xF0000000'u32) == 0: n += 4; v = v shl 4
  if (v and 0xC0000000'u32) == 0: n += 2; v = v shl 2
  if (v and 0x80000000'u32) == 0: n += 1
  n

proc dwaQuantSmall*(alt: uint32, smallbits: var int, srcFloat, errTol: float32,
    smalldelta: var float32, smallest: var uint32, isLarge: bool) =
  ## Shared body of TEST_QUANT_ALTERNATE_SMALL/LARGE.
  let bits = dwaCountSetBits(uint16(alt and 0xFFFF))
  if bits < smallbits:
    let delta = if isLarge: halfToFloat(uint16(alt and 0xFFFF)) - srcFloat
      else: srcFloat - halfToFloat(uint16(alt and 0xFFFF))
    if delta < errTol:
      smallbits = bits; smalldelta = delta; smallest = alt
  elif bits == smallbits:
    let delta = if isLarge: halfToFloat(uint16(alt and 0xFFFF)) - srcFloat
      else: srcFloat - halfToFloat(uint16(alt and 0xFFFF))
    if delta < smalldelta:
      smallest = alt
      smalldelta = delta
      smallbits = bits

proc dwaQDenormTol(abssrc, tolSig: uint32, errTol,
    srcFloat: float32): uint32 =
  let tsigshift = 32 - dwaCountLeadingZeros(tolSig)
  let npow2 = 1'u32 shl tsigshift
  let lowermask = npow2 - 1
  let mask = not lowermask
  let mask2 = mask xor npow2
  var smallest = abssrc
  var smallbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
  var smalldelta = errTol
  var alt = abssrc and mask2
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  alt = abssrc and mask
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  alt = (abssrc + npow2) and mask
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, true)
  alt = (abssrc + (npow2 shl 1)) and mask
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, true)
  smallest

proc dwaQGeneric(abssrc, tolSig: uint32, errTol,
    srcFloat: float32): uint32 =
  let tsigshift = 32 - dwaCountLeadingZeros(tolSig)
  let npow2 = 1'u32 shl tsigshift
  let lowermask = npow2 - 1
  let mask = not lowermask
  let mask2 = mask xor npow2
  let srcMaskedVal = abssrc and lowermask
  let extrabit = tolSig > srcMaskedVal
  let mask3 = mask2 xor (((npow2 shl 1) * (if extrabit: 1'u32 else: 0'u32)) or
    ((npow2 shr 1) * (if extrabit: 0'u32 else: 1'u32)))
  var smallest = abssrc
  var smallbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
  var smalldelta = errTol
  var alt: uint32
  if extrabit:
    alt = abssrc and mask3
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask2
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  elif (abssrc and npow2) != 0:
    alt = abssrc and mask2
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask3
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  else:
    alt = abssrc and mask2
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    alt = abssrc and mask3
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  alt = (abssrc + npow2) and mask
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, true)
  smallest

proc dwaQEqualExp(abssrc, tolSig: uint32, errTol,
    srcFloat: float32): uint32 =
  const npow2 = 0x0800'u32
  let lowermask = npow2 - 1
  let mask = not lowermask
  let mask2 = mask xor npow2
  let srcMaskedVal = abssrc and lowermask
  let extrabit = tolSig > srcMaskedVal
  let mask3 = mask2 xor (((npow2 shl 1) * (if extrabit: 1'u32 else: 0'u32)) or
    ((npow2 shr 1) * (if extrabit: 0'u32 else: 1'u32)))
  var smallest = abssrc
  var smallbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
  var smalldelta = errTol
  var alt: uint32
  if srcMaskedVal == abssrc:
    alt = abssrc and mask3
    dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  else:
    let alt0 = abssrc and mask2
    let alt1 = abssrc and mask
    if alt0 == alt1:
      alt = abssrc and mask3
      dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
      alt = alt1
      dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
    else:
      alt = alt0
      dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
      alt = alt1
      dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, false)
  alt = (abssrc + npow2) and mask
  dwaQuantSmall(alt, smallbits, srcFloat, errTol, smalldelta, smallest, true)
  smallest

proc dwaQCloseExp*(abssrc, tolSig: uint32, errTol,
    srcFloat: float32): uint32 =
  const npow2 = 0x0400'u32
  let lowermask = npow2 - 1
  let mask = not lowermask
  let mask2 = mask xor npow2
  let srcMaskedVal = abssrc and lowermask
  let extrabit = tolSig > srcMaskedVal
  let mask3 = mask2 xor (((npow2 shl 1) * (if extrabit: 1'u32 else: 0'u32)) or
    ((npow2 shr 1) * (if extrabit: 0'u32 else: 1'u32)))
  var alternates: array[3, uint32]
  if (abssrc and npow2) == 0:
    if extrabit:
      alternates[0] = abssrc and mask3
      alternates[1] = abssrc and mask
    else:
      alternates[0] = abssrc and mask
      alternates[1] = abssrc and mask3
  else:
    if extrabit:
      alternates[0] = abssrc and mask3
      alternates[1] = abssrc and mask2
      let d1 = srcFloat - halfToFloat(uint16(alternates[1] and 0xFFFF))
      if d1 >= errTol:
        alternates[1] = abssrc and mask
    else:
      alternates[0] = abssrc and mask2
      alternates[1] = abssrc and mask3
      let d0 = srcFloat - halfToFloat(uint16(alternates[0] and 0xFFFF))
      if d0 >= errTol:
        alternates[0] = abssrc and mask
  alternates[2] = (abssrc + npow2) and mask
  var smallest = abssrc
  var smallbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
  var smalldelta = errTol
  dwaQuantSmall(alternates[0], smallbits, srcFloat, errTol, smalldelta,
    smallest, false)
  dwaQuantSmall(alternates[1], smallbits, srcFloat, errTol, smalldelta,
    smallest, false)
  dwaQuantSmall(alternates[2], smallbits, srcFloat, errTol, smalldelta,
    smallest, true)
  smallest

proc dwaQLargerSig(abssrc, npow2, mask: uint32, errTol,
    srcFloat: float32): uint32 =
  let mask2 = mask xor (npow2 or (npow2 shr 1))
  let alt0 = abssrc and mask2
  let alt1 = (abssrc + npow2) and mask
  let bits0 = dwaCountSetBits(uint16(alt0 and 0xFFFF))
  let bits1 = dwaCountSetBits(uint16(alt1 and 0xFFFF))
  if bits1 < bits0:
    let delta = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta < errTol:
      return alt1
    let delta2 = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    if delta2 < errTol:
      return alt0
  elif bits1 == bits0:
    let delta = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta < errTol:
      return (if delta1 < delta: alt1 else: alt0)
    if delta1 < errTol:
      return alt1
  else:
    let delta = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    if delta < errTol:
      return alt0
    let srcbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
    if bits1 < srcbits:
      let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
      if delta1 < errTol:
        return alt1
  abssrc

proc dwaQSmallerSig(abssrc, npow2, mask: uint32, errTol,
    srcFloat: float32): uint32 =
  let alt0 = abssrc and mask
  let alt1 = (abssrc + npow2) and mask
  let bits0 = dwaCountSetBits(uint16(alt0 and 0xFFFF))
  let bits1 = dwaCountSetBits(uint16(alt1 and 0xFFFF))
  if bits1 < bits0:
    let delta = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta < errTol:
      return alt1
    let delta2 = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    if delta2 < errTol:
      return alt0
  elif bits1 == bits0:
    let delta = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta < errTol:
      return (if delta1 < delta: alt1 else: alt0)
    if delta1 < errTol:
      return alt1
  else:
    let delta = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    if delta < errTol:
      return alt0
    let srcbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
    if bits1 < srcbits:
      let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
      if delta1 < errTol:
        return alt1
  abssrc

proc dwaQEqualSig(abssrc, npow2, mask: uint32, errTol,
    srcFloat: float32): uint32 =
  var alt0 = abssrc and mask
  let alt1 = (abssrc + npow2) and mask
  var delta0 = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
  if delta0 >= errTol:
    let mask2 = mask xor (npow2 or (npow2 shr 1))
    alt0 = abssrc and mask2
    delta0 = srcFloat - halfToFloat(uint16(alt0 and 0xFFFF))
    if delta0 >= errTol:
      let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
      if delta1 < errTol:
        let bits1 = dwaCountSetBits(uint16(alt1 and 0xFFFF))
        let srcbits = dwaCountSetBits(uint16(abssrc and 0xFFFF))
        if bits1 < srcbits:
          return alt1
      return abssrc
  let bits0 = dwaCountSetBits(uint16(alt0 and 0xFFFF))
  let bits1 = dwaCountSetBits(uint16(alt1 and 0xFFFF))
  if bits1 < bits0:
    let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta1 < errTol: return alt1
  elif bits1 == bits0:
    let delta1 = halfToFloat(uint16(alt1 and 0xFFFF)) - srcFloat
    if delta1 < delta0: return alt1
  alt0

proc dwaQDefault(abssrc, tolSig: uint32, errTol,
    srcFloat: float32): uint32 =
  let tsigshift = 32 - dwaCountLeadingZeros(tolSig)
  let npow2 = 1'u32 shl tsigshift
  let lowermask = npow2 - 1
  let mask = not lowermask
  let srcMaskedVal = abssrc and lowermask
  if srcMaskedVal > tolSig:
    return dwaQLargerSig(abssrc, npow2, mask, errTol, srcFloat)
  elif srcMaskedVal < tolSig:
    return dwaQSmallerSig(abssrc, npow2, mask, errTol, srcFloat)
  dwaQEqualSig(abssrc, npow2, mask, errTol, srcFloat)

proc dwaAlgoQuantize*(src, herrTol: uint16, errTol,
    srcFloat: float32): uint16 =
  let s = uint32(src)
  let abssrc = s and 0x7FFF'u32
  let af = if srcFloat < 0.0'f32: -srcFloat else: srcFloat
  let srcExpBiased = s and 0x7C00'u32
  let tolExpBiased = uint32(herrTol) and 0x7C00'u32
  if srcExpBiased == 0x7C00'u32:
    return src
  if af < errTol:
    return 0
  let expDiff = (srcExpBiased - tolExpBiased) shr 10
  var tolSig = (((uint32(herrTol) and 0x3FF'u32) or (1'u32 shl 10)) shr expDiff)
  if tolExpBiased == 0:
    if expDiff == 0 or expDiff == 1:
      tolSig = uint32(herrTol) and 0x3FF'u32
      if tolSig == 0:
        return src
      return uint16((s and 0x8000'u32) or
        dwaQGeneric(abssrc, tolSig, errTol, af))
    tolSig = uint32(herrTol) and 0x3FF'u32
    if tolSig == 0:
      return src
    tolSig = tolSig shr expDiff
    if tolSig == 0:
      tolSig = 1
    return uint16((s and 0x8000'u32) or
      dwaQDenormTol(abssrc, tolSig, errTol, af))
  if tolSig == 0:
    return src
  if expDiff > 1 or srcExpBiased == 0:
    return uint16((s and 0x8000'u32) or
      dwaQDefault(abssrc, tolSig, errTol, af))
  if expDiff == 0:
    return uint16((s and 0x8000'u32) or
      dwaQEqualExp(abssrc, tolSig, errTol, af))
  uint16((s and 0x8000'u32) or
    dwaQCloseExp(abssrc, tolSig, errTol, af))

proc dwaRleCompress*(data: openArray[uint8]): seq[uint8] =
  ## Pure RLE counts (no delta/interleave; the DWA RLE path operates on
  ## pre-split byte planes). Mirrors internal_rle_compress (MIN 3/MAX 127).
  result = @[]
  let n = data.len
  var runs = 0
  var rune = 1
  while runs < n:
    var curcount = 0
    while rune < n and data[runs] == data[rune] and curcount < 127:
      inc(rune); inc(curcount)
    if curcount >= 2:
      result.add(uint8(curcount))
      result.add(data[runs])
      runs = rune
    else:
      inc(curcount)
      while rune < n and ((rune + 1 >= n or data[rune] != data[rune+1]) or
          (rune + 2 >= n or data[rune+1] != data[rune+2])) and
          curcount < 127:
        inc(curcount); inc(rune)
      result.add(uint8((256 - curcount) and 0xFF))
      while runs < rune:
        result.add(data[runs]); inc(runs)
    inc(rune)

proc dwaWriteRules(rules: openArray[DwaRule], names: seq[string],
    typs: seq[int]): seq[uint8] =
  ## Relevant-rules blob: u16 LE total size (incl. itself), then for each
  ## default rule matching >= 1 channel: NUL-terminated suffix + value
  ## byte + type byte. Mirrors DwaCompressor_writeRelevantChannelRules.
  result = @[0'u8, 0]
  for r in rules:
    var hit = false
    for c in 0..<names.len:
      if dwaMatch(r, dwaFindSuffix(names[c]), typs[c]):
        hit = true
        break
    if not hit: continue
    for ch in r.suffix: result.add(uint8(ch))
    result.add(0)
    result.add(uint8(((r.cscIdx + 1) shl 4) or (r.scheme shl 2) or
      (if r.ci: 1 else: 0)))
    result.add(uint8(r.typ))
  let n = result.len
  result[0] = uint8(n and 0xFF)
  result[1] = uint8(n shr 8)

proc dwaQuantizeZig*(halfZig: var array[64, uint16], dct: array[64, float32],
    qtbl: openArray[float32], htbl: openArray[uint16]) =
  ## Forward-DCT coeffs -> quantized half zigzag (XDR). Mirrors
  ## quantizeCoeffAndZigXDR (including its inv_remap == dwaZigzag order).
  for i in countup(0, 60, 4):
    for k in 0..3:
      let j = i + k
      let h0 = dwaFloatToHalf(dct[j])
      let q = dwaAlgoQuantize(h0, htbl[j], qtbl[j], halfToFloat(h0))
      halfZig[dwaZigzag[j]] = q

proc dwaRleAc*(halfZig: openArray[uint16], acBuf: var seq[uint16]) =
  ## RLE the AC zigzag (verbatim / short-run / EOB 0xFF00). Mirrors
  ## LossyDctEncoder_rleAc.
  var d = 1
  while d < 64:
    if halfZig[d] != 0:
      acBuf.add(halfZig[d])
      inc(d)
      continue
    var runLen = 1
    while d + runLen < 64 and halfZig[d + runLen] == 0:
      inc(runLen)
    if runLen == 1:
      acBuf.add(halfZig[d])
    elif runLen + d == 64:
      acBuf.add(0xFF00'u16)
    else:
      acBuf.add(0xFF00'u16 or uint16(runLen))
    d += runLen

proc dwaEncodeGroup*(halves: seq[seq[uint16]], chs: openArray[int],
    qbe: float32, toNonlin: seq[uint16], hasNonlin: openArray[bool],
    w, h: int, acBuf: var seq[uint16],
    dcBufs: var seq[seq[uint16]]): bool =
  ## Encode one LOSSY group (1 or 3 channels): mirror-pad 8x8 blocks,
  ## toNonlinear, forward CSC, forward DCT, quantize + zigzag. AC goes to
  ## the shared stream in block order; DC is collected per channel (the
  ## chunk packs DC grouped by channel). Mirrors LossyDctEncoder_execute.
  let ng = chs.len
  var qtY = newSeq[float32](64)
  var htY = newSeq[uint16](64)
  var qtC = newSeq[float32](64)
  var htC = newSeq[uint16](64)
  for i in 0..<64:
    qtY[i] = (qbe * float32(dwaJpegQy[i])) / 10.0'f32
    htY[i] = dwaFloatToHalf(qtY[i])
    qtC[i] = (qbe * float32(dwaJpegQc[i])) / 17.0'f32
    htC[i] = dwaFloatToHalf(qtC[i])
  let nbx = (w + 7) div 8
  let nby = (h + 7) div 8
  for by in 0..<nby:
    for bx in 0..<nbx:
      var dct: array[3, array[64, float32]]
      for g in 0..<ng:
        let ci = chs[g]
        for y in 0..<8:
          var vy = by * 8 + y
          if vy >= h: vy = h - (vy - (h - 1))
          if vy < 0: vy = h - 1
          for x in 0..<8:
            var vx = bx * 8 + x
            if vx >= w: vx = w - (vx - (w - 1))
            if vx < 0: vx = w - 1
            var hv = halves[ci][vy * w + vx]
            if hasNonlin[g]:
              hv = toNonlin[hv]
            dct[g][y * 8 + x] = halfToFloat(hv)
      if ng == 3:
        dwaCscFwd(dct[0], dct[1], dct[2])
      for g in 0..<ng:
        dwaTranspose8(dct[g])
        dwaDctForward(dct[g])
        dwaTranspose8(dct[g])
        dwaDctForward(dct[g])
        let (qt, ht) = if g == 0: (qtY, htY) else: (qtC, htC)
        var hz: array[64, uint16]
        dwaQuantizeZig(hz, dct[g], qt, ht)
        dcBufs[chs[g]].add(hz[0])
        dwaRleAc(hz, acBuf)
  true

proc dwaApplyChunk*(planar: openArray[uint8], w, rows: int,
    channels: seq[ExrChannel], chanBytes: seq[int],
    level = 45.0'f32): tuple[ok: bool, blk: seq[uint8]] =
  ## Full DWAA/DWAB chunk encode: channel classification (default rules),
  ## CSC + wavelet... no - DCT + quantize + Huffman, RLE/UNKNOWN paths.
  ## Falls back to raw planar when the encoding does not win.
  var poff = newSeq[int](channels.len)
  var lineBytes = 0
  for ci in 0..<channels.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  let exp = rows * lineBytes
  ensureDwaTables()
  var names = newSeq[string](channels.len)
  var typs = newSeq[int](channels.len)
  for i, c in channels:
    names[i] = c.name
    typs[i] = int(c.pixelType)
  let (scheme, sets) = dwaClassify(names, typs, dwaDefaultRules)
  let qbe = level / 100000.0'f32
  # per-channel half rows (float source clamped to half range)
  var halfRows = newSeq[seq[uint16]](channels.len)
  for ci in 0..<channels.len:
    if scheme[ci] != 1: continue
    halfRows[ci] = newSeq[uint16](w * rows)
    if channels[ci].pixelType == 2:
      for y in 0..<rows:
        for x in 0..<w:
          let o = y * lineBytes + poff[ci] + x * 4
          let u = uint32(planar[o]) or (uint32(planar[o+1]) shl 8) or
            (uint32(planar[o+2]) shl 16) or (uint32(planar[o+3]) shl 24)
          var f = cast[float32](u)
          if f > 65504.0'f32: f = 65504.0'f32
          elif f < -65504.0'f32: f = -65504.0'f32
          halfRows[ci][y * w + x] = dwaFloatToHalf(f)
    elif channels[ci].pixelType == 1:
      for y in 0..<rows:
        for x in 0..<w:
          let o = y * lineBytes + poff[ci] + x * 2
          halfRows[ci][y * w + x] =
            uint16(planar[o]) or (uint16(planar[o+1]) shl 8)
  var acBuf: seq[uint16] = @[]
  var dcBufs = newSeq[seq[uint16]](channels.len)
  var hasNonlin = newSeq[bool](channels.len)
  for ci in 0..<channels.len:
    if scheme[ci] == 1 and not channels[ci].pLinear:
      hasNonlin[ci] = true
  var processed = newSeq[bool](channels.len)
  for s in sets:
    var chs = [s[0], s[1], s[2]]
    # CSC always uses the nonlinear table (reference ignores pLinear here)
    var nl = @[true, true, true]
    if not dwaEncodeGroup(halfRows, chs, qbe, dwaToNonLinearTab, nl,
        w, rows, acBuf, dcBufs):
      return (false, @[])
    for c in chs: processed[c] = true
  for ci in 0..<channels.len:
    if scheme[ci] == 1 and not processed[ci]:
      if not dwaEncodeGroup(halfRows, [ci], qbe, dwaToNonLinearTab,
          [hasNonlin[ci]], w, rows, acBuf, dcBufs):
        return (false, @[])
      processed[ci] = true
  # DC grouped by channel (sets first, then singles), like the decoder
  var dcBuf: seq[uint16] = @[]
  for s in sets:
    for g in 0..2:
      for v in dcBufs[s[g]]: dcBuf.add(v)
  for ci in 0..<channels.len:
    if scheme[ci] == 1 and not dwaInSets(ci, sets):
      for v in dcBufs[ci]: dcBuf.add(v)
  # RLE + UNKNOWN buffers
  var rlePlanes = newSeq[seq[uint8]](channels.len)
  var rleRawLen = 0
  for ci in 0..<channels.len:
    if scheme[ci] != 2: continue
    let cb = chanBytes[ci]
    rlePlanes[ci] = newSeq[uint8](w * rows * cb)
    for y in 0..<rows:
      for x in 0..<w:
        let o = y * lineBytes + poff[ci] + x * cb
        for b in 0..<cb:
          rlePlanes[ci][b * w * rows + y * w + x] = planar[o + b]
    rleRawLen += w * rows * cb
  var unkBuf: seq[uint8] = @[]
  for ci in 0..<channels.len:
    if scheme[ci] != 0: continue
    let cb = chanBytes[ci]
    for y in 0..<rows:
      let o = y * lineBytes + poff[ci]
      for i in 0..<w * cb: unkBuf.add(planar[o + i])
  # assemble: 11 u64 + rules + UNKNOWN + AC + DC + RLE
  var outp = newSeq[uint8](88)
  proc putU64(o, v: int) =
    var vv = uint64(v)
    for b in 0..7:
      outp[o+b] = uint8(vv and 0xFF)
      vv = vv shr 8
  var acBytes: seq[uint8] = @[]
  if acBuf.len > 0:
    let (hok, huf) = hufCompress(acBuf)
    if not hok:
      return (false, @[])
    acBytes = huf
  var dcBytes: seq[uint8] = @[]
  if dcBuf.len > 0:
    var zb = newSeq[uint8](dcBuf.len * 2)
    for i, v in dcBuf:
      zb[2*i] = uint8(v and 0xFF); zb[2*i+1] = uint8(v shr 8)
    separateHalves(zb)
    samplesToDifferences(zb)
    let cr = deflateZlib(zb, 6)
    if not cr.ok:
      return (false, @[])
    dcBytes = cr.value
  var unkBytes: seq[uint8] = @[]
  if unkBuf.len > 0:
    let cr = deflateZlib(unkBuf, 9)
    if not cr.ok:
      return (false, @[])
    unkBytes = cr.value
  var rleBytes: seq[uint8] = @[]
  var rleUncLen = 0
  if rleRawLen > 0:
    var flat: seq[uint8] = @[]
    for ci in 0..<channels.len:
      if scheme[ci] != 2: continue
      for b in rlePlanes[ci]: flat.add(b)
    let rc = dwaRleCompress(flat)
    rleUncLen = rc.len
    let cr = deflateZlib(rc, 9)
    if not cr.ok:
      return (false, @[])
    rleBytes = cr.value
  let rules = dwaWriteRules(dwaDefaultRules, names, typs)
  putU64(0, 2)
  putU64(8, unkBuf.len)
  putU64(16, unkBytes.len)
  putU64(24, acBytes.len)
  putU64(32, dcBytes.len)
  putU64(40, rleBytes.len)
  putU64(48, rleUncLen)
  putU64(56, rleRawLen)
  putU64(64, acBuf.len)
  putU64(72, dcBuf.len)
  putU64(80, 0)
  for b in rules: outp.add(b)
  for b in unkBytes: outp.add(b)
  for b in acBytes: outp.add(b)
  for b in dcBytes: outp.add(b)
  for b in rleBytes: outp.add(b)
  if outp.len < exp:
    return (true, outp)
  (true, @planar)
