# DWAA/DWAB decode (lossy DCT; mirrors OpenEXRCore internal_dwa_*.h scalar paths).
# Included by openexr.nim (shares its scope: halfToFloat/floatToHalf,
# hufDecompress, inflateZlib, differencesToSamples/interleaveHalves,
# ExrChannel, ImageResult/ok/err/decodingError).
#
# Per-chunk layout (all u64 LE): version, unknownUnc, unknownCmp, acCmp,
# dcCmp, rleCmp, rleUnc, rleRaw, acCount, dcCount, acCompression (11 u64),
# then (v2+) u16 ruleSize + channel rules, then UNKNOWN zlib, AC Huffman,
# DC zip, RLE zlib+RLE blobs. LOSSY channels decode as 8x8 float DCT blocks
# with R->G,B grouped via CSC when they share a name prefix.

{.passL: "-lm".}
proc dwaPowf(x, y: float32): float32 {.importc: "powf", header: "<math.h>".}
proc dwaLogf(x: float32): float32 {.importc: "logf", header: "<math.h>".}
proc dwaCosf(x: float32): float32 {.importc: "cosf", header: "<math.h>".}

proc dwaFdiv*(a, b: float32): float32 {.noinline.} =
  ## Runtime float32 division. Stops the compiler folding constant
  ## quotients (e.g. 1/2.2) in float64, which rounds 1 ulp away from the
  ## float32 result the reference computes at runtime.
  a / b

proc dwaFmul*(a, b: float32): float32 {.noinline.} =
  ## Runtime float32 multiply (same constant-folding hazard as dwaFdiv).
  a * b

proc dwaFloatToHalf*(f: float32): uint16 =
  ## Imath imath_float_to_half, exactly: round-half-even, NaN payload
  ## preserved, overflow (> 0x477FEFFF) rounds to infinity. (Our shared
  ## floatToHalf clamps overflow to HALF_MAX instead, which matches the
  ## B44/PXR24 call sites but not DWA.)
  let x = cast[uint32](f)
  let ui = x and 0x7FFFFFFF'u32
  var ret = uint16((x shr 16) and 0x8000)
  if ui >= 0x38800000'u32:
    if ui >= 0x7F800000'u32:
      ret = ret or 0x7C00'u16
      if ui == 0x7F800000'u32: return ret
      let m = uint16((ui and 0x7FFFFF'u32) shr 13)
      return ret or m or (if m == 0: 1'u16 else: 0'u16)
    if ui > 0x477FEFFF'u32:
      return ret or 0x7C00'u16
    var u = ui - 0x38000000'u32
    u = (u + 0xFFF'u32 + ((u shr 13) and 1'u32)) shr 13
    return ret or uint16(u)
  if ui < 0x33000001'u32:
    return ret
  let e = ui shr 23
  let shift = 0x7E'u32 - e
  let m = 0x800000'u32 or (ui and 0x7FFFFF'u32)
  let r = (uint64(m) shl (32 - shift)) and 0xFFFFFFFF'u64
  ret = ret or uint16(m shr shift)
  if r > 0x80000000'u64 or (r == 0x80000000'u64 and (ret and 1'u16) != 0):
    inc(ret)
  ret
var dwaToLinearTab*: seq[uint16]
var dwaToNonLinearTab*: seq[uint16]
var dwaDctA*, dwaDctB*, dwaDctC*, dwaDctD*, dwaDctE*, dwaDctF*, dwaDctG*: float32

proc ensureDwaTables*() =
  ## Perceptual half<->half LUTs + scalar DCT constants, exactly per
  ## internal_dwa_table_init.c (float32 libm ops) and internal_dwa_simd.h.
  if dwaToLinearTab.len == 65536: return
  dwaToLinearTab = newSeq[uint16](65536)
  dwaToNonLinearTab = newSeq[uint16](65536)
  for i in 0..<65536:
    let x = uint16(i)
    if x == 0 or (x and 0x7C00'u16) == 0x7C00'u16:
      dwaToLinearTab[i] = 0
      dwaToNonLinearTab[i] = 0
    else:
      let f = halfToFloat(x)
      let af = if f < 0.0'f32: -f else: f
      let sign = if f < 0.0'f32: -1.0'f32 else: 1.0'f32
      var lz: float32
      if af <= 1.0'f32:
        lz = sign * dwaPowf(af, 2.2'f32)
      else:
        lz = sign * dwaPowf(9.02501329156'f32, af - 1.0'f32)
      dwaToLinearTab[i] = dwaFloatToHalf(lz)
      var nz: float32
      if af <= 1.0'f32:
        nz = dwaPowf(af, dwaFdiv(1.0'f32, 2.2'f32))
      else:
        nz = dwaFdiv(dwaLogf(af), 2.2'f32) + 1.0'f32
      dwaToNonLinearTab[i] = dwaFloatToHalf(sign * nz)
  let pi = 3.14159'f32
  dwaDctA = 0.5'f32 * dwaCosf(dwaFdiv(pi, 4.0'f32))
  dwaDctB = 0.5'f32 * dwaCosf(dwaFdiv(pi, 16.0'f32))
  dwaDctC = 0.5'f32 * dwaCosf(dwaFdiv(pi, 8.0'f32))
  dwaDctD = 0.5'f32 * dwaCosf(dwaFdiv(dwaFmul(3.0'f32, pi), 16.0'f32))
  dwaDctE = 0.5'f32 * dwaCosf(dwaFdiv(dwaFmul(5.0'f32, pi), 16.0'f32))
  dwaDctF = 0.5'f32 * dwaCosf(dwaFdiv(dwaFmul(3.0'f32, pi), 8.0'f32))
  dwaDctG = 0.5'f32 * dwaCosf(dwaFdiv(dwaFmul(7.0'f32, pi), 16.0'f32))

# dst[i] = half_to_float(src[zig[i]]); inverse of the encoder zigzag.
const dwaZigzag = [0, 1, 5, 6, 14, 15, 27, 28,
  2, 4, 7, 13, 16, 26, 29, 42,
  3, 8, 12, 17, 25, 30, 41, 43,
  9, 11, 18, 24, 31, 40, 44, 53,
  10, 19, 23, 32, 39, 45, 52, 54,
  20, 22, 33, 38, 46, 51, 55, 60,
  21, 34, 37, 47, 50, 56, 59, 61,
  35, 36, 48, 49, 57, 58, 62, 63]

proc dwaFromHalfZigzag*(src: openArray[uint16], dst: var array[64, float32]) =
  for i in 0..<64:
    dst[i] = halfToFloat(src[dwaZigzag[i]])

proc dwaCscInv*(y, cb, cr: float32, r, g, b: var float32) =
  ## Inverse 709 CSC (Y'CbCr -> R'G'B', no offset). Scalar reference version.
  r = y + 1.5747'f32 * cr
  g = y - 0.1873'f32 * cb - 0.4682'f32 * cr
  b = y + 1.8556'f32 * cb

proc dwaDctDcOnly*(d: var array[64, float32]) =
  let v = d[0] * 3.535536e-01'f32 * 3.535536e-01'f32
  for i in 0..<64: d[i] = v

proc dwaUnRleAc*(ac: openArray[uint16], pos: var int,
    hz: var array[64, uint16]): tuple[ok: bool, lnz: int] =
  ## Expand one block's AC run symbols (0xFFxx: xx zeros, 0 = end of block).
  var dc = 1
  var lnz = 0
  while dc < 64:
    if pos >= ac.len: return (false, 0)
    let v = ac[pos]; inc(pos)
    if (v and 0xFF00'u16) == 0xFF00'u16:
      let cnt = int(v and 0xFF)
      dc += (if cnt == 0: 64 else: cnt)
    else:
      lnz = dc
      hz[dc] = v
      inc(dc)
  (true, lnz)

proc dwaRleDecompress*(data: openArray[uint8], expected: int): seq[uint8] =
  ## Plain RLE counts (no delta/interleave; the DWA RLE path splits bytes
  ## but skips the biased predictor). Caller checks length.
  result = newSeq[uint8]()
  var i = 0
  while i < data.len and result.len != expected:
    let c = cast[int8](data[i]); inc(i)
    if c < 0:
      let k = int(-c)
      if i + k > data.len: return result
      for j in 0..<k: result.add(data[i+j])
      i += k
    else:
      if i >= data.len: return result
      let v = data[i]; inc(i)
      for _ in 0..int(c): result.add(v)

proc dwaDctInverse*(d: var array[64, float32]) =
  ## Full 8x8 inverse DCT with the AVX association order and the sAvxCoef
  ## matrix constants (internal_dwa_simd.h IDCT_AVX_BODY), not the scalar
  ## a..g formulation. On x86-64 with AVX the reference dispatches to the
  ## AVX version, whose pairwise-sum association and differently-rounded
  ## constants change low bits vs scalar; matching it is required for
  ## bit-exact DWA decode on this platform. (On ARM the reference uses
  ## scalar/NEON paths, which round differently there too; DWA is
  ## inherently platform-specific. See dwaDctInverseScalar.)
  const A = 3.535536e-01'f32
  const B = 4.903927e-01'f32
  const C = 4.619398e-01'f32
  const D = 4.157349e-01'f32
  const E = 2.777855e-01'f32
  const F = 1.913422e-01'f32
  const G = 9.754573e-02'f32
  const nA = -3.535536e-01'f32
  const nB = -4.903927e-01'f32
  const nC = -4.619398e-01'f32
  const nE = -2.777855e-01'f32
  const nF = -1.913422e-01'f32
  const nG = -9.754573e-02'f32
  # row pass: 4x4 M1/M2 matrix multiply, ((t0+t1)+(t2+t3)) accumulation
  for row in 0..<8:
    let rp = row * 8
    let x0 = d[rp+0]; let x1 = d[rp+1]; let x2 = d[rp+2]; let x3 = d[rp+3]
    let x4 = d[rp+4]; let x5 = d[rp+5]; let x6 = d[rp+6]; let x7 = d[rp+7]
    let e0 = ((x0*A + x2*C) + (x4*A + x6*F))
    let e1 = ((x0*A + x2*F) + (x4*nA + x6*nC))
    let e2 = ((x0*A + x2*nF) + (x4*nA + x6*C))
    let e3 = ((x0*A + x2*nC) + (x4*A + x6*nF))
    let o0 = ((x1*B + x3*D) + (x5*E + x7*G))
    let o1 = ((x1*D + x3*nG) + (x5*nB + x7*nE))
    let o2 = ((x1*E + x3*nB) + (x5*G + x7*D))
    let o3 = ((x1*G + x3*nE) + (x5*D + x7*nB))
    d[rp+0] = e0+o0; d[rp+1] = e1+o1; d[rp+2] = e2+o2; d[rp+3] = e3+o3
    d[rp+4] = e3-o3; d[rp+5] = e2-o2; d[rp+6] = e1-o1; d[rp+7] = e0-o0
  # column pass: same structure transposed, with the AVX odd/even order
  for col in 0..<8:
    let d0 = d[col]; let d1 = d[8+col]; let d2 = d[16+col]; let d3 = d[24+col]
    let d4 = d[32+col]; let d5 = d[40+col]; let d6 = d[48+col]; let d7 = d[56+col]
    let odd0 = ((B*d1 + D*d3) + (E*d5 + G*d7))
    let odd1 = ((D*d1 - (G*d3 + B*d5)) - E*d7)
    let odd2 = (((E*d1 - B*d3) + G*d5) + D*d7)
    let odd3 = ((G*d1 + D*d5) - (E*d3 + B*d7))
    let aaAdd = (A*d0 + A*d4)
    let aaSub = (A*d0 - A*d4)
    let cfAdd = (C*d2 + F*d6)
    let cfSub = (F*d2 - C*d6)
    let ev0 = (aaAdd + cfAdd)
    let ev3 = (aaAdd - cfAdd)
    let ev1 = (aaSub + cfSub)
    let ev2 = (aaSub - cfSub)
    d[col] = ev0+odd0; d[8+col] = ev1+odd1
    d[16+col] = ev2+odd2; d[24+col] = ev3+odd3
    d[32+col] = ev3-odd3; d[40+col] = ev2-odd2
    d[48+col] = ev1-odd1; d[56+col] = ev0-odd0

proc dwaDctInverseScalar*(d: var array[64, float32]) =
  ## Scalar-order 8x8 inverse DCT (dctInverse8x8_scalar, zeroedRows=0).
  ## Matches the reference on ARM/NEON and on x86 without AVX; kept for
  ## documentation and differential testing. x86-64 with AVX (this
  ## machine) uses dwaDctInverse above.
  let a = dwaDctA; let b = dwaDctB; let c = dwaDctC; let dd = dwaDctD
  let e = dwaDctE; let f = dwaDctF; let g = dwaDctG
  var alpha, beta, theta, gamma: array[4, float32]
  for row in 0..<8:
    let rp = row * 8
    alpha[0] = c * d[rp+2]
    alpha[1] = f * d[rp+2]
    alpha[2] = c * d[rp+6]
    alpha[3] = f * d[rp+6]
    beta[0] = b * d[rp+1] + dd * d[rp+3] + e * d[rp+5] + g * d[rp+7]
    beta[1] = dd * d[rp+1] - g * d[rp+3] - b * d[rp+5] - e * d[rp+7]
    beta[2] = e * d[rp+1] - b * d[rp+3] + g * d[rp+5] + dd * d[rp+7]
    beta[3] = g * d[rp+1] - e * d[rp+3] + dd * d[rp+5] - b * d[rp+7]
    theta[0] = a * (d[rp+0] + d[rp+4])
    theta[3] = a * (d[rp+0] - d[rp+4])
    theta[1] = alpha[0] + alpha[3]
    theta[2] = alpha[1] - alpha[2]
    gamma[0] = theta[0] + theta[1]
    gamma[1] = theta[3] + theta[2]
    gamma[2] = theta[3] - theta[2]
    gamma[3] = theta[0] - theta[1]
    d[rp+0] = gamma[0] + beta[0]
    d[rp+1] = gamma[1] + beta[1]
    d[rp+2] = gamma[2] + beta[2]
    d[rp+3] = gamma[3] + beta[3]
    d[rp+4] = gamma[3] - beta[3]
    d[rp+5] = gamma[2] - beta[2]
    d[rp+6] = gamma[1] - beta[1]
    d[rp+7] = gamma[0] - beta[0]
  for col in 0..<8:
    alpha[0] = c * d[16+col]
    alpha[1] = f * d[16+col]
    alpha[2] = c * d[48+col]
    alpha[3] = f * d[48+col]
    beta[0] = b * d[8+col] + dd * d[24+col] + e * d[40+col] + g * d[56+col]
    beta[1] = dd * d[8+col] - g * d[24+col] - b * d[40+col] - e * d[56+col]
    beta[2] = e * d[8+col] - b * d[24+col] + g * d[40+col] + dd * d[56+col]
    beta[3] = g * d[8+col] - e * d[24+col] + dd * d[40+col] - b * d[56+col]
    theta[0] = a * (d[col] + d[32+col])
    theta[3] = a * (d[col] - d[32+col])
    theta[1] = alpha[0] + alpha[3]
    theta[2] = alpha[1] - alpha[2]
    gamma[0] = theta[0] + theta[1]
    gamma[1] = theta[3] + theta[2]
    gamma[2] = theta[3] - theta[2]
    gamma[3] = theta[0] - theta[1]
    d[col] = gamma[0] + beta[0]
    d[8+col] = gamma[1] + beta[1]
    d[16+col] = gamma[2] + beta[2]
    d[24+col] = gamma[3] + beta[3]
    d[32+col] = gamma[3] - beta[3]
    d[40+col] = gamma[2] - beta[2]
    d[48+col] = gamma[1] - beta[1]
    d[56+col] = gamma[0] - beta[0]

type DwaRule = object
  suffix: string
  scheme: int # 0 unknown (zlib), 1 lossy DCT, 2 RLE
  typ: int # 0 uint, 1 half, 2 float
  cscIdx: int # -1 none, else 0/1/2 (R/G/B slot)
  ci: bool # case-insensitive match

let dwaDefaultRules = @[
  DwaRule(suffix: "R", scheme: 1, typ: 1, cscIdx: 0, ci: false),
  DwaRule(suffix: "R", scheme: 1, typ: 2, cscIdx: 0, ci: false),
  DwaRule(suffix: "G", scheme: 1, typ: 1, cscIdx: 1, ci: false),
  DwaRule(suffix: "G", scheme: 1, typ: 2, cscIdx: 1, ci: false),
  DwaRule(suffix: "B", scheme: 1, typ: 1, cscIdx: 2, ci: false),
  DwaRule(suffix: "B", scheme: 1, typ: 2, cscIdx: 2, ci: false),
  DwaRule(suffix: "Y", scheme: 1, typ: 1, cscIdx: -1, ci: false),
  DwaRule(suffix: "Y", scheme: 1, typ: 2, cscIdx: -1, ci: false),
  DwaRule(suffix: "BY", scheme: 1, typ: 1, cscIdx: -1, ci: false),
  DwaRule(suffix: "BY", scheme: 1, typ: 2, cscIdx: -1, ci: false),
  DwaRule(suffix: "RY", scheme: 1, typ: 1, cscIdx: -1, ci: false),
  DwaRule(suffix: "RY", scheme: 1, typ: 2, cscIdx: -1, ci: false),
  DwaRule(suffix: "A", scheme: 2, typ: 0, cscIdx: -1, ci: false),
  DwaRule(suffix: "A", scheme: 2, typ: 1, cscIdx: -1, ci: false),
  DwaRule(suffix: "A", scheme: 2, typ: 2, cscIdx: -1, ci: false)]

let dwaLegacyRules = @[
  DwaRule(suffix: "r", scheme: 1, typ: 1, cscIdx: 0, ci: true),
  DwaRule(suffix: "r", scheme: 1, typ: 2, cscIdx: 0, ci: true),
  DwaRule(suffix: "red", scheme: 1, typ: 1, cscIdx: 0, ci: true),
  DwaRule(suffix: "red", scheme: 1, typ: 2, cscIdx: 0, ci: true),
  DwaRule(suffix: "g", scheme: 1, typ: 1, cscIdx: 1, ci: true),
  DwaRule(suffix: "g", scheme: 1, typ: 2, cscIdx: 1, ci: true),
  DwaRule(suffix: "grn", scheme: 1, typ: 1, cscIdx: 1, ci: true),
  DwaRule(suffix: "grn", scheme: 1, typ: 2, cscIdx: 1, ci: true),
  DwaRule(suffix: "green", scheme: 1, typ: 1, cscIdx: 1, ci: true),
  DwaRule(suffix: "green", scheme: 1, typ: 2, cscIdx: 1, ci: true),
  DwaRule(suffix: "b", scheme: 1, typ: 1, cscIdx: 2, ci: true),
  DwaRule(suffix: "b", scheme: 1, typ: 2, cscIdx: 2, ci: true),
  DwaRule(suffix: "blu", scheme: 1, typ: 1, cscIdx: 2, ci: true),
  DwaRule(suffix: "blu", scheme: 1, typ: 2, cscIdx: 2, ci: true),
  DwaRule(suffix: "blue", scheme: 1, typ: 1, cscIdx: 2, ci: true),
  DwaRule(suffix: "blue", scheme: 1, typ: 2, cscIdx: 2, ci: true),
  DwaRule(suffix: "y", scheme: 1, typ: 1, cscIdx: -1, ci: true),
  DwaRule(suffix: "y", scheme: 1, typ: 2, cscIdx: -1, ci: true),
  DwaRule(suffix: "by", scheme: 1, typ: 1, cscIdx: -1, ci: true),
  DwaRule(suffix: "by", scheme: 1, typ: 2, cscIdx: -1, ci: true),
  DwaRule(suffix: "ry", scheme: 1, typ: 1, cscIdx: -1, ci: true),
  DwaRule(suffix: "ry", scheme: 1, typ: 2, cscIdx: -1, ci: true),
  DwaRule(suffix: "a", scheme: 2, typ: 0, cscIdx: -1, ci: true),
  DwaRule(suffix: "a", scheme: 2, typ: 1, cscIdx: -1, ci: true),
  DwaRule(suffix: "a", scheme: 2, typ: 2, cscIdx: -1, ci: true)]

proc dwaLower(c: char): char =
  if c >= 'A' and c <= 'Z': chr(ord(c) + 32) else: c

proc dwaFindSuffix(name: string): string =
  var p = -1
  for i in 0..<name.len:
    if name[i] == '.': p = i
  if p < 0: name else: name[p+1..^1]

proc dwaMatch(r: DwaRule, suf: string, typ: int): bool =
  if r.typ != typ: return false
  if r.ci:
    if r.suffix.len != suf.len: return false
    for i in 0..<suf.len:
      if dwaLower(r.suffix[i]) != dwaLower(suf[i]): return false
    true
  else:
    r.suffix == suf

proc dwaParseRules*(data: openArray[uint8], pos: var int,
    left: int): tuple[ok: bool, rules: seq[DwaRule]] =
  ## Rules blob: u16 LE total size (incl. itself), then NUL-terminated
  ## suffix + value byte ((cscIdx+1)<<4 | scheme<<2 | ci) + type byte.
  if left < 2: return (false, @[])
  let rs = int(data[pos]) or (int(data[pos+1]) shl 8)
  if rs < 2 or rs > left: return (false, @[])
  var rules: seq[DwaRule] = @[]
  var q = pos + 2
  let stop = pos + rs
  while q < stop:
    var s = ""
    while true:
      if q >= stop or s.len > 128: return (false, @[])
      if data[q] == 0: inc(q); break
      s.add(char(data[q])); inc(q)
    if q + 2 > stop: return (false, @[])
    let value = data[q]; let typ = data[q+1]; q += 2
    let cscIdx = int(value shr 4) - 1
    if cscIdx < -1 or cscIdx > 2: return (false, @[])
    let sch = int((value shr 2) and 3)
    if sch > 2: return (false, @[])
    if int(typ) > 2: return (false, @[])
    rules.add(DwaRule(suffix: s, scheme: sch, typ: int(typ),
      cscIdx: cscIdx, ci: (value and 1) != 0))
  pos = stop
  (true, rules)

proc dwaClassify(names: seq[string], typs: seq[int],
    rules: openArray[DwaRule]): tuple[scheme: seq[int],
    sets: seq[array[3, int]]] =
  let n = names.len
  var scheme = newSeq[int](n)
  var pnames = newSeq[string](n)
  var pidx = newSeq[array[3, int]](n)
  var npref = 0
  for c in 0..<n:
    let nm = names[c]
    let suf = dwaFindSuffix(nm)
    let pre = if suf.len == nm.len: "" else: nm[0 ..< nm.len - suf.len]
    var mi = -1
    for k in 0..<npref:
      if pnames[k] == pre: mi = k; break
    if mi < 0:
      mi = npref
      pnames[mi] = pre
      pidx[mi] = [-1, -1, -1]
      inc(npref)
    for r in rules:
      if dwaMatch(r, suf, typs[c]):
        scheme[c] = r.scheme
        if r.cscIdx >= 0:
          pidx[mi][r.cscIdx] = c
  var sets: seq[array[3, int]] = @[]
  for k in 0..<npref:
    if pidx[k][0] >= 0 and pidx[k][1] >= 0 and pidx[k][2] >= 0:
      sets.add(pidx[k])
  (scheme, sets)

proc dwaInSets(ci: int, sets: seq[array[3, int]]): bool =
  for s in sets:
    if s[0] == ci or s[1] == ci or s[2] == ci: return true
  false

proc dwaDecodeGroup(ac: openArray[uint16], acPos: var int,
    dc: openArray[uint16], dcCurs: var seq[int],
    chs: openArray[int],
    halfRows: var seq[seq[uint16]],
    linTabs: openArray[seq[uint16]], hasLin: openArray[bool],
    w, h: int): bool =
  ## Decode one LOSSY group (1 or 3 channels) over a w*h tile.
  let ng = chs.len
  let nbx = (w + 7) div 8
  let nby = (h + 7) div 8
  let loX = w - (nbx - 1) * 8
  let loY = h - (nby - 1) * 8
  var rb = newSeq[seq[uint16]](ng)
  for g in 0..<ng: rb[g] = newSeq[uint16](nbx * 64)
  var dct: array[3, array[64, float32]]
  for by in 0..<nby:
    let maxY = if by == nby - 1: loY else: 8
    for bx in 0..<nbx:
      for g in 0..<ng:
        let ci = chs[g]
        var hz: array[64, uint16]
        if dcCurs[ci] >= dc.len: return false
        hz[0] = dc[dcCurs[ci]]; inc(dcCurs[ci])
        let (ok, lnz) = dwaUnRleAc(ac, acPos, hz)
        if not ok: return false
        if lnz == 0:
          dct[g][0] = halfToFloat(hz[0])
          dwaDctDcOnly(dct[g])
        else:
          dwaFromHalfZigzag(hz, dct[g])
          dwaDctInverse(dct[g])
      if ng == 3:
        for i in 0..<64:
          var r, gg, b: float32
          dwaCscInv(dct[0][i], dct[1][i], dct[2][i], r, gg, b)
          dct[0][i] = r; dct[1][i] = gg; dct[2][i] = b
      for g in 0..<ng:
        let base = bx * 64
        for i in 0..<64:
          rb[g][base + i] = dwaFloatToHalf(dct[g][i])
    for g in 0..<ng:
      let ci = chs[g]
      for y in 0..<maxY:
        let gy = by * 8 + y
        for bx in 0..<nbx:
          let maxX = if bx == nbx - 1: loX else: 8
          let srcB = bx * 64 + y * 8
          let dstB = gy * w + bx * 8
          if hasLin[ci]:
            for x in 0..<maxX:
              halfRows[ci][dstB + x] = linTabs[ci][rb[g][srcB + x]]
          else:
            for x in 0..<maxX:
              halfRows[ci][dstB + x] = rb[g][srcB + x]
  true

proc dwaUndoChunk*(comp: openArray[uint8], w, rows: int,
    channels: seq[ExrChannel], chanBytes: seq[int]): ImageResult[seq[uint8]] =
  ## Full DWAA/DWAB chunk decode to planar-per-scanline rows. Mirrors
  ## DwaCompressor_uncompress (scalar paths; SIMD only reorders work).
  var poff = newSeq[int](channels.len)
  var lineBytes = 0
  for ci in 0..<channels.len:
    poff[ci] = lineBytes
    lineBytes += w * chanBytes[ci]
  let exp = rows * lineBytes
  if comp.len == exp:
    var blk = newSeq[uint8](exp)
    for i in 0..<exp: blk[i] = comp[i]
    return ok(blk)
  if comp.len < 88:
    return err[seq[uint8]](decodingError("exr: short dwa chunk"))
  ensureDwaTables()
  var hdr: array[11, uint64]
  for i in 0..<11:
    var v = 0'u64
    for b in 0..7: v = v or (uint64(comp[i*8+b]) shl (8*b))
    hdr[i] = v
  if hdr[0] > 2:
    return err[seq[uint8]](decodingError("exr: bad dwa version"))
  let unkUnc = hdr[1]; let unkCmp = hdr[2]
  let acCmp = hdr[3]; let dcCmp = hdr[4]
  let rleCmp = hdr[5]; let rleUnc = hdr[6]; let rleRaw = hdr[7]
  let acCnt = hdr[8]; let dcCnt = hdr[9]
  if hdr[10] != 0:
    # scanline DWAA/DWAB always use static Huffman; DEFLATE AC only
    # appears in tiled files, which we do not support.
    return err[seq[uint8]](decodingError("exr: dwa ac compression"))
  let clen = uint64(comp.len)
  if unkCmp > clen or acCmp > clen or dcCmp > clen or rleCmp > clen:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  var cursor = 88
  var rules: seq[DwaRule]
  if hdr[0] >= 2:
    let (ok, r) = dwaParseRules(comp, cursor, comp.len - cursor)
    if not ok:
      return err[seq[uint8]](decodingError("exr: corrupt dwa rules"))
    rules = r
  else:
    rules = dwaLegacyRules
  if unkCmp + acCmp + dcCmp + rleCmp > uint64(comp.len - cursor):
    return err[seq[uint8]](decodingError("exr: short dwa chunk"))
  var names = newSeq[string](channels.len)
  var typs = newSeq[int](channels.len)
  for i, c in channels:
    names[i] = c.name
    typs[i] = int(c.pixelType)
  let (scheme, sets) = dwaClassify(names, typs, rules)
  var reqUnk, reqRle: uint64 = 0
  for ci in 0..<channels.len:
    let need = uint64(w) * uint64(rows) * uint64(chanBytes[ci])
    if scheme[ci] == 1 and channels[ci].pixelType == 0:
      return err[seq[uint8]](decodingError("exr: dwa uint lossy"))
    if scheme[ci] == 0: reqUnk += need
    elif scheme[ci] == 2: reqRle += need
  if reqUnk > 0:
    if unkUnc < reqUnk or unkCmp == 0:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  elif unkUnc != 0 or unkCmp != 0:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  if reqRle > 0:
    if rleRaw < reqRle or rleCmp == 0 or rleUnc == 0:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  elif rleRaw != 0 or rleCmp != 0 or rleUnc != 0:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  let nbx = (w + 7) div 8
  let nby = (rows + 7) div 8
  var needDc = 0'u64
  for ci in 0..<channels.len:
    if scheme[ci] == 1: needDc += uint64(nbx * nby)
  if dcCnt < needDc:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  let uOff = cursor
  let aOff = uOff + int(unkCmp)
  let dOff = aOff + int(acCmp)
  let rOff = dOff + int(dcCmp)
  var unkBuf: seq[uint8] = @[]
  if unkCmp > 0:
    let inf = inflateZlib(comp.toOpenArray(uOff, uOff+int(unkCmp)-1),
      int(unkUnc))
    if not inf.ok or inf.value.len != int(unkUnc):
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    unkBuf = inf.value
  var acVals: seq[uint16] = @[]
  if acCmp > 0:
    if acCnt == 0:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    let (ok, raw) = hufDecompress(
      comp.toOpenArray(aOff, aOff+int(acCmp)-1), int(acCnt))
    if not ok or raw.len != int(acCnt):
      return err[seq[uint8]](decodingError("exr: corrupt dwa huffman"))
    acVals = raw
  elif acCnt != 0:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  var dcVals: seq[uint16] = @[]
  if dcCmp > 0:
    let nBytes = int(dcCnt) * 2
    let inf = inflateZlib(comp.toOpenArray(dOff, dOff+int(dcCmp)-1), nBytes)
    if not inf.ok or inf.value.len != nBytes:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    var zb = inf.value
    differencesToSamples(zb)
    interleaveHalves(zb)
    dcVals = newSeq[uint16](int(dcCnt))
    for i in 0..<dcVals.len:
      dcVals[i] = uint16(zb[2*i]) or (uint16(zb[2*i+1]) shl 8)
  elif dcCnt != 0:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  var rleRawBuf: seq[uint8] = @[]
  if rleCmp > 0:
    let inf = inflateZlib(comp.toOpenArray(rOff, rOff+int(rleCmp)-1),
      int(rleUnc))
    if not inf.ok or inf.value.len != int(rleUnc):
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    rleRawBuf = dwaRleDecompress(inf.value, int(rleRaw))
    if rleRawBuf.len != int(rleRaw):
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  var dcCurs = newSeq[int](channels.len)
  var dcOff = 0
  for s in sets:
    for g in 0..2:
      dcCurs[s[g]] = dcOff
      dcOff += nbx * nby
  for ci in 0..<channels.len:
    if scheme[ci] == 1 and not dwaInSets(ci, sets):
      dcCurs[ci] = dcOff
      dcOff += nbx * nby
  if uint64(dcOff) > dcCnt:
    return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
  var halfRows = newSeq[seq[uint16]](channels.len)
  var hasLin = newSeq[bool](channels.len)
  var linTabs = newSeq[seq[uint16]](channels.len)
  for ci in 0..<channels.len:
    if scheme[ci] == 1:
      halfRows[ci] = newSeq[uint16](w * rows)
      # NB: the reference applies toLinear unconditionally for CSC sets
      # (ignoring pLinear); singles honor pLinear. Match it exactly.
      if not channels[ci].pLinear or dwaInSets(ci, sets):
        hasLin[ci] = true
        linTabs[ci] = dwaToLinearTab
  var acPos = 0
  var processed = newSeq[bool](channels.len)
  for s in sets:
    for c in [s[0], s[1], s[2]]:
      if scheme[c] != 1:
        return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    if not dwaDecodeGroup(acVals, acPos, dcVals, dcCurs, s, halfRows,
        linTabs, hasLin, w, rows):
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    for c in [s[0], s[1], s[2]]: processed[c] = true
  for ci in 0..<channels.len:
    if scheme[ci] == 1 and not processed[ci]:
      if not dwaDecodeGroup(acVals, acPos, dcVals, dcCurs, [ci], halfRows,
          linTabs, hasLin, w, rows):
        return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
      processed[ci] = true
  var output = newSeq[uint8](exp)
  for ci in 0..<channels.len:
    if scheme[ci] != 1: continue
    if channels[ci].pixelType == 1:
      for y in 0..<rows:
        for x in 0..<w:
          let v = halfRows[ci][y * w + x]
          let o = y * lineBytes + poff[ci] + x * 2
          output[o] = uint8(v and 0xFF)
          output[o+1] = uint8(v shr 8)
    elif channels[ci].pixelType == 2:
      for y in 0..<rows:
        for x in 0..<w:
          let u = cast[uint32](halfToFloat(halfRows[ci][y * w + x]))
          let o = y * lineBytes + poff[ci] + x * 4
          output[o] = uint8(u and 0xFF)
          output[o+1] = uint8((u shr 8) and 0xFF)
          output[o+2] = uint8((u shr 16) and 0xFF)
          output[o+3] = uint8(u shr 24)
  var rleOff = 0
  for ci in 0..<channels.len:
    if scheme[ci] != 2: continue
    let cb = chanBytes[ci]
    let need = w * rows * cb
    if rleOff + need > rleRawBuf.len:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    for y in 0..<rows:
      for x in 0..<w:
        let o = y * lineBytes + poff[ci] + x * cb
        for b in 0..<cb:
          output[o+b] = rleRawBuf[rleOff + b * w * rows + y * w + x]
    rleOff += need
  var unkOff = 0
  for ci in 0..<channels.len:
    if scheme[ci] != 0: continue
    let cb = chanBytes[ci]
    let need = w * rows * cb
    if unkOff + need > unkBuf.len:
      return err[seq[uint8]](decodingError("exr: corrupt dwa chunk"))
    for y in 0..<rows:
      let src = unkOff + y * w * cb
      let dst = y * lineBytes + poff[ci]
      for i in 0..<w * cb: output[dst+i] = unkBuf[src+i]
    unkOff += need
  ok(output)