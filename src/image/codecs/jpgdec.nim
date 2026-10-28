## JPEG codec — references/image/src/codecs/jpeg/ + zune-jpeg/jpeg-encoder
## Pure Nim baseline DCT: SOI/APP/DQT/SOF0+SOF1(8-bit)/DHT/DRI/SOS/RST/EOI,
## Huffman, separable float IDCT, 4:4:4/4:2:2/4:2:0 (+general H/V replication),
## YCbCr/RGB/gray/CMYK-Adobe. Progressive (SOF2) spectra + refinements.
import ../color
import ../error
import ../buffer
import ../dynamic
import ../simd
when defined(linux) or defined(macosx):
  import posix
when defined(decodeProfile):
  import std/times
  import std/posix
  proc peakMb(): float64 =
    var ru: Rusage
    discard getrusage(RUSAGE_SELF, addr ru)
    when defined(macosx): float64(ru.ru_maxrss) / 1e6
    else: float64(ru.ru_maxrss) / 1e3

# ---------- zigzag (natural order -> index) computed from diagonals ----------

var Zigzag {.global.}: array[64, int]
var Unzigzag {.global.}: array[64, int]

proc initZigzag() =
  var i = 0
  for s in 0..14:
    if s mod 2 == 0:
      var r = min(s, 7)
      while r >= max(0, s - 7):
        Zigzag[r * 8 + (s - r)] = i
        Unzigzag[i] = r * 8 + (s - r)
        inc i; dec r
    else:
      var r = max(0, s - 7)
      while r <= min(s, 7):
        Zigzag[r * 8 + (s - r)] = i
        Unzigzag[i] = r * 8 + (s - r)
        inc i; inc r

initZigzag()

# ---------- separable float DCT via shared JPEG tables (see image/simd) ----------

proc idctBlock(coef: array[64, float64], qt: array[64, int]): array[64, uint8] =
  idctBlockSimd(coef, qt)

proc idctScaledBlock(coef: array[64, float64], qt: array[64, int],
    m: int): array[64, uint8] =
  ## Reduced block output (m = 1, 2, 4) via the full SIMD IDCT followed
  ## by an in-block DxD box average (d = 8 div m). m = 8 is the plain
  ## full path. Matches libjpeg `-scale` output within its own integer
  ## rounding noise, and is bit-exact vs full decode + identical box
  ## downsample (the committed test oracle).
  if m == 8:
    return idctBlock(coef, qt)
  let full = idctBlock(coef, qt)
  let d = 8 div m
  let n = d * d
  let half = n div 2
  for oy in 0..<m:
    for ox in 0..<m:
      var s = 0
      for dy in 0..<d:
        for dx in 0..<d:
          s += int(full[(oy*d+dy)*8 + (ox*d+dx)])
      result[oy*m+ox] = uint8((s + half) div n)

# ---------- bit reader with stuffed bytes ----------

type BitReader = object
  data: seq[uint8]
  pos: int
  buf: uint32
  nbits: int

proc fillByte(r: var BitReader): bool =
  if r.pos >= r.data.len: return false
  let b = r.data[r.pos]; inc(r.pos)
  if b == 0xFF:
    if r.pos >= r.data.len: return false
    let c = r.data[r.pos]; inc(r.pos)
    if c != 0x00: return false # markers pre-stripped; unexpected here
    r.buf = r.buf or (uint32(0xFF) shl (24 - r.nbits))
  else:
    r.buf = r.buf or (uint32(b) shl (24 - r.nbits))
  r.nbits += 8
  true

proc readBits(r: var BitReader, n: int): tuple[ok: bool, v: int] =
  if n == 0: return (true, 0)
  while r.nbits < n:
    if not r.fillByte(): return (false, 0)
  let v = int(r.buf shr (32 - n))
  r.buf = r.buf shl n
  r.nbits -= n
  (true, v)

proc receiveExtend(r: var BitReader, s: int): tuple[ok: bool, v: int] =
  if s == 0: return (true, 0)
  let (ok, v) = r.readBits(s)
  if not ok: return (false, 0)
  if v < (1 shl (s - 1)): (true, v - (1 shl s) + 1)
  else: (true, v)

# ---------- Huffman tables ----------

type HuffTable = object
  minCode: array[17, int]
  maxCode: array[17, int]
  valPtr: array[17, int]
  symbols: seq[int]

proc buildHuff(counts: array[16, int], symbols: seq[int]): tuple[ok: bool, t: HuffTable] =
  var t = HuffTable()
  var code = 0
  var k = 0
  for l in 1..16:
    if counts[l-1] == 0:
      t.minCode[l] = -1; t.maxCode[l] = -1
    else:
      t.minCode[l] = code
      t.maxCode[l] = code + counts[l-1] - 1
      t.valPtr[l] = k
      k += counts[l-1]
      code += counts[l-1]
    code = code shl 1
  if k != symbols.len: return (false, t)
  t.symbols = symbols
  (true, t)

proc decodeHuff(r: var BitReader, t: HuffTable): tuple[ok: bool, sym: int] =
  var code = 0
  for l in 1..16:
    let (ok, b) = r.readBits(1)
    if not ok: return (false, 0)
    code = (code shl 1) or b
    if t.minCode[l] >= 0 and code >= t.minCode[l] and code <= t.maxCode[l]:
      return (true, t.symbols[t.valPtr[l] + code - t.minCode[l]])
  (false, 0)

# ---------- color conversion (scalar single-pixel; see image/simd) ----------

# ---------- frame structures ----------

proc rawPages(bytes: int): pointer =
  ## OS-page-backed zeroed memory for giant decode transients (144 MB
  ## coefficient grid at 24 MP). Nim's allocator never returns freed
  ## chunks to the OS (verified: 194 MB stays resident after the decode
  ## buffers are freed), so a viewer would sit on ~200 MB per big photo.
  ## munmap/rawFreePages returns pages deterministically. Zero-filled by
  ## the OS, matching the newSeq semantics the progressive refinement
  ## path relies on (unwritten coefficients read as zero).
  if bytes <= 0: return nil
  when defined(linux) or defined(macosx):
    result = mmap(nil, bytes, PROT_READ or PROT_WRITE,
      MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
    if result == MAP_FAILED: result = nil
  else:
    result = alloc0(bytes) # fallback: zeroed, but retained by GC heap

proc rawFreePages(p: pointer, bytes: int) =
  if p == nil: return
  when defined(linux) or defined(macosx):
    discard munmap(p, bytes)
  else:
    dealloc(p)

type
  CoefGrid = object
    ## Manually-allocated coefficient block grid (progressive JPEG state).
    ## Same value semantics as `seq[array[64, int32]]` but bypasses the GC
    ## heap: 144 MB on a 24 MP photo. GC freelists stay mapped (resident),
    ## while munmap (via rawFreePages) returns pages to the OS, so a viewer
    ## decoding one big photo no longer sits on ~200 MB after the decode
    ## finishes.
    ## Copies are a compile error — index in place like JpegComponent.
    p: ptr UncheckedArray[array[64, int32]]
    n: int
  PixBlocks = object
    ## Same idea for IDCT output blocks (36 MB at 24 MP).
    p: ptr UncheckedArray[array[64, uint8]]
    n: int

proc `=destroy`(g: var CoefGrid) =
  if g.p != nil:
    rawFreePages(g.p, g.n * sizeof(array[64, int32]))
    g.p = nil
    g.n = 0

proc `=copy`(dst: var CoefGrid, src: CoefGrid) {.
    error: "CoefGrid must not be copied; index in place".}

proc `=sink`(dst: var CoefGrid, src: CoefGrid) =
  if dst.p != nil: rawFreePages(dst.p, dst.n * sizeof(array[64, int32]))
  wasMoved(dst)
  dst.p = src.p
  dst.n = src.n

proc `=destroy`(b: var PixBlocks) =
  if b.p != nil:
    rawFreePages(b.p, b.n * sizeof(array[64, uint8]))
    b.p = nil
    b.n = 0

proc `=copy`(dst: var PixBlocks, src: PixBlocks) {.
    error: "PixBlocks must not be copied; index in place".}

proc `=sink`(dst: var PixBlocks, src: PixBlocks) =
  if dst.p != nil: rawFreePages(dst.p, dst.n * sizeof(array[64, uint8]))
  wasMoved(dst)
  dst.p = src.p
  dst.n = src.n

proc newCoefGrid(n: int): CoefGrid =
  ## Zero-initialized like newSeq (progressive refinement reads unwritten
  ## coefficients as zero, e.g. the eobrun skip path).
  result.n = n
  if n > 0:
    result.p = cast[ptr UncheckedArray[array[64, int32]]](
      rawPages(n * sizeof(array[64, int32])))
    if result.p == nil:
      raise newException(OutOfMemDefect, "jpeg: out of memory")

proc newPixBlocks(n: int): PixBlocks =
  result.n = n
  if n > 0:
    result.p = cast[ptr UncheckedArray[array[64, uint8]]](
      rawPages(n * sizeof(array[64, uint8])))
    if result.p == nil:
      raise newException(OutOfMemDefect, "jpeg: out of memory")

proc len(g: var CoefGrid): int = g.n
proc len(b: var PixBlocks): int = b.n

proc `[]`(g: var CoefGrid, i: int): var array[64, int32] =
  assert i >= 0 and i < g.n
  g.p[i]

proc `[]=`(g: var CoefGrid, i: int, v: array[64, int32]) =
  assert i >= 0 and i < g.n
  g.p[i] = v

proc `[]`(b: var PixBlocks, i: int): var array[64, uint8] =
  assert i >= 0 and i < b.n
  b.p[i]

proc `[]=`(b: var PixBlocks, i: int, v: array[64, uint8]) =
  assert i >= 0 and i < b.n
  b.p[i] = v

type JpegComponent = object
  ## NOTE: copying a JpegComponent is a compile error (its `blocks`
  ## buffer is manually managed). Never `let c = comps[i]` /
  ## `for c in comps` in any loop — always index `comps[i]` in place.
  id: uint8
  h*, v*: int
  tq*: int
  dcPred*: int
  blocks*: PixBlocks

proc jpegDimensions*(data: seq[uint8]): ImageResult[tuple[w, h: uint32]] =
  ## SOF-only header scan: image dimensions without decoding pixels.
  ## Used to pick a scaled-decode denominator before the full decode.
  if data.len < 2 or data[0] != 0xFF or data[1] != 0xD8:
    return err[tuple[w, h: uint32]](decodingError("jpeg: bad SOI"))
  var pos = 2
  while true:
    if pos + 4 > data.len:
      return err[tuple[w, h: uint32]](decodingError("jpeg: truncated"))
    if data[pos] != 0xFF:
      return err[tuple[w, h: uint32]](decodingError("jpeg: expected marker"))
    var m = data[pos+1]; pos += 2
    while m == 0xFF:
      if pos >= data.len:
        return err[tuple[w, h: uint32]](decodingError("jpeg: truncated"))
      m = data[pos]; inc(pos)
    if m == 0xD8 or m in {0xD0..0xD7, 0x01}:
      continue
    if m == 0xD9:
      return err[tuple[w, h: uint32]](decodingError("jpeg: no SOF"))
    if pos + 2 > data.len:
      return err[tuple[w, h: uint32]](decodingError("jpeg: truncated segment"))
    let segLen = (int(data[pos]) shl 8) or int(data[pos+1]); pos += 2
    if segLen < 2 or pos + segLen - 2 > data.len:
      return err[tuple[w, h: uint32]](decodingError("jpeg: truncated segment"))
    if m in {0xC0, 0xC1, 0xC2}:
      if segLen < 7:
        return err[tuple[w, h: uint32]](decodingError("jpeg: truncated SOF"))
      let h = (int(data[pos+1]) shl 8) or int(data[pos+2])
      let w = (int(data[pos+3]) shl 8) or int(data[pos+4])
      return ok((uint32(w), uint32(h)))
    if m == 0xDA:
      return err[tuple[w, h: uint32]](decodingError("jpeg: SOS before SOF"))
    pos += segLen - 2

proc decodeJpeg*(data: seq[uint8], denom = 1): ImageResult[DynamicImage] =
  ## Baseline / progressive JPEG decode. `denom` 2/4/8 emits a
  ## 1/denom-scaled image (full IDCT + in-block box average,
  ## libjpeg `-scale` style); 1 is full resolution. Output dims are
  ## ceil(w/denom).
  if denom notin [1, 2, 4, 8]:
    return err[DynamicImage](paramError(pkGeneric, "jpeg: denom 1/2/4/8"))
  if data.len < 2 or data[0] != 0xFF or data[1] != 0xD8:
    return err[DynamicImage](decodingError("jpeg: bad SOI"))
  var pos = 2
  var qts: array[4, array[64, int]]
  var qtsSet: array[4, bool]
  var dcTables: array[4, HuffTable]
  var acTables: array[4, HuffTable]
  var dcSet: array[4, bool]
  var acSet: array[4, bool]
  var width = 0; var height = 0
  var comps: seq[JpegComponent] = @[]
  var sofFound = false
  var adobeTransform = -1
  var restartInterval = 0
  var scanComps: seq[tuple[comp: int, dc, ac: int]] = @[]
  var scanStart = -1
  # progressive state (SOF2 only; baseline path below is untouched)
  var progressive = false
  var pcoef: seq[CoefGrid] = @[] # per comp: raw coeff blocks (manual)
  var scanCount = 0
  var pMaxH = 1; var pMaxV = 1
  var pMcuX = 0; var pMcuY = 0
  # per (comp, zigzag-k) last point transform, -1 = never coded. Real
  # encoders split first scans into sub-bands (1-5, 6-63) and refine the
  # union (1-63), so continuity is tracked per coefficient, not per band.
  var coefAl: array[4, array[64, int]]
  for ci in 0..3:
    for k in 0..63: coefAl[ci][k] = -1
  template need(n: int): bool = pos + n <= data.len
  when defined(decodeProfile):
    var tProfEntropy = 0.0
    var tProfIdct = 0.0
    var tProfAsm = 0.0
    var tProfGather = 0.0
    var tProfConvert = 0.0

  proc buildCleanScan(startPos: int): tuple[clean: seq[uint8], nextPos: int] =
    ## Entropy segment from startPos to the next marker; strips RSTn and
    ## stuffed 0x00 bytes, like the baseline path below.
    var clean: seq[uint8] = @[]
    var qq = startPos
    while qq + 1 < data.len:
      if data[qq] == 0xFF:
        let c2 = data[qq+1]
        if c2 == 0x00:
          clean.add([0xFF'u8, 0x00]); qq += 2
        elif c2 >= 0xD0 and c2 <= 0xD7:
          qq += 2
        else:
          break
      else:
        clean.add(data[qq]); inc(qq)
    (clean, qq)
  var progFinish = false
  while true:
    if pos + 1 >= data.len:
      return err[DynamicImage](decodingError("jpeg: truncated"))
    if data[pos] != 0xFF:
      return err[DynamicImage](decodingError("jpeg: expected marker"))
    var m = data[pos+1]; pos += 2
    while m == 0xFF:
      if pos >= data.len:
        return err[DynamicImage](decodingError("jpeg: truncated"))
      m = data[pos]; inc(pos)
    if m == 0xD8: continue
    if m in {0xD0..0xD7, 0x01}: continue
    if m == 0xD9:
      if progressive and scanCount > 0:
        progFinish = true
        break
      return err[DynamicImage](decodingError("jpeg: EOI before SOS"))
    if not need(2):
      return err[DynamicImage](decodingError("jpeg: truncated segment"))
    let segLen = (int(data[pos]) shl 8) or int(data[pos+1]); pos += 2
    if segLen < 2 or not need(segLen - 2):
      return err[DynamicImage](decodingError("jpeg: truncated segment"))
    let body = data[pos..<pos+segLen-2]
    case m
    of 0xE0..0xEF, 0xFE:
      if m == 0xEE and body.len >= 12 and body[0]==uint8('A') and
          body[1]==uint8('d') and body[2]==uint8('o') and
          body[3]==uint8('b') and body[4]==uint8('e'):
        adobeTransform = int(body[11])
    of 0xDB:
      var q = 0
      while q < body.len:
        let info = int(body[q]); inc(q)
        let tq = info and 15; let prec = info shr 4
        if tq > 3 or (prec != 0 and prec != 1):
          return err[DynamicImage](decodingError("jpeg: bad DQT"))
        let tabLen = if prec == 0: 64 else: 128
        if q + tabLen > body.len:
          return err[DynamicImage](decodingError("jpeg: truncated DQT"))
        for i in 0..63:
          qts[tq][Unzigzag[i]] =
            if prec == 0: int(body[q+i])
            else: (int(body[q+2*i]) shl 8) or int(body[q+2*i+1])
        q += tabLen
        qtsSet[tq] = true
    of 0xC0, 0xC1, 0xC2:
      if body.len < 6:
        return err[DynamicImage](decodingError("jpeg: truncated SOF"))
      if int(body[0]) != 8:
        return err[DynamicImage](unsupportedError(ukGenericFeature, "jpeg: precision"))
      height = (int(body[1]) shl 8) or int(body[2])
      width = (int(body[3]) shl 8) or int(body[4])
      let nc = int(body[5])
      if nc notin [1, 3, 4] or body.len < 6 + nc * 3:
        return err[DynamicImage](unsupportedError(ukGenericFeature, "jpeg: components"))
      if width == 0 or height == 0:
        return err[DynamicImage](decodingError("jpeg: empty image"))
      comps = @[]
      for i in 0..<nc:
        let h = int(body[6+3*i+1] shr 4); let v = int(body[6+3*i+1] and 15)
        if h < 1 or h > 4 or v < 1 or v > 4:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "jpeg: sampling factors"))
        comps.add(JpegComponent(id: body[6+3*i], h: h, v: v,
          tq: int(body[6+3*i+2]), dcPred: 0, blocks: PixBlocks()))
      sofFound = true
      if m == 0xC2:
        progressive = true
        pMaxH = 1; pMaxV = 1
        for i in 0..<comps.len: pMaxH = max(pMaxH, comps[i].h); pMaxV = max(pMaxV, comps[i].v)
        let mcuW = 8 * pMaxH; let mcuH = 8 * pMaxV
        pMcuX = (width + mcuW - 1) div mcuW
        pMcuY = (height + mcuH - 1) div mcuH
        pcoef = @[]
        for i in 0..<comps.len:
          pcoef.add(newCoefGrid(pMcuX * comps[i].h * pMcuY * comps[i].v))
    of 0xC4:
      var q = 0
      while q < body.len:
        let info = int(body[q]); inc(q)
        let tc = info shr 4; let th = info and 15
        if th > 3 or (tc != 0 and tc != 1):
          return err[DynamicImage](decodingError("jpeg: bad DHT"))
        if q + 16 > body.len:
          return err[DynamicImage](decodingError("jpeg: truncated DHT"))
        var counts: array[16, int]
        var total = 0
        for i in 0..15: counts[i] = int(body[q+i]); total += counts[i]
        q += 16
        if q + total > body.len:
          return err[DynamicImage](decodingError("jpeg: truncated DHT symbols"))
        var syms: seq[int] = @[]
        for i in 0..<total: syms.add(int(body[q+i]))
        q += total
        let (ok, t) = buildHuff(counts, syms)
        if not ok:
          return err[DynamicImage](decodingError("jpeg: bad Huffman table"))
        if tc == 0: dcTables[th] = t; dcSet[th] = true
        else: acTables[th] = t; acSet[th] = true
    of 0xDD:
      if body.len < 2:
        return err[DynamicImage](decodingError("jpeg: truncated DRI"))
      restartInterval = (int(body[0]) shl 8) or int(body[1])
    of 0xDA:
      if not sofFound:
        return err[DynamicImage](decodingError("jpeg: SOS before SOF"))
      if body.len < 3:
        return err[DynamicImage](decodingError("jpeg: truncated SOS"))
      let ns = int(body[0])
      if ns < 1 or ns > comps.len or body.len < 1 + ns * 2 + 3:
        return err[DynamicImage](decodingError("jpeg: bad SOS"))
      scanComps = @[]
      for i in 0..<ns:
        let cs = body[1+2*i]
        var ci = -1
        for k in 0..<comps.len:
          if comps[k].id == cs: ci = k; break
        if ci < 0:
          return err[DynamicImage](decodingError("jpeg: SOS unknown component"))
        scanComps.add((ci, int(body[1+2*i+1] shr 4), int(body[1+2*i+1] and 15)))
      let ss = int(body[1+ns*2]); let se = int(body[1+ns*2+1])
      let ah = int(body[1+ns*2+2] shr 4); let al = int(body[1+ns*2+2] and 15)
      if not progressive:
        if ns != comps.len or ss != 0 or se != 63 or ah != 0 or al != 0:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "jpeg: only baseline scans"))
        for sc in scanComps:
          if not dcSet[sc.dc] or not acSet[sc.ac]:
            return err[DynamicImage](decodingError("jpeg: missing Huffman table"))
        for i in 0..<comps.len:
          if not qtsSet[comps[i].tq]:
            return err[DynamicImage](decodingError("jpeg: missing quant table"))
        pos += segLen - 2
        scanStart = pos
        break
      # ---- progressive scan: accumulate coefficients, continue to next scan
      if se > 63 or ss > se:
        return err[DynamicImage](decodingError("jpeg: bad spectral band"))
      if se > 0 and ns != 1:
        return err[DynamicImage](decodingError("jpeg: interleaved AC scan"))
      if ss == 0 and se == 0:
        for sc in scanComps:
          if not dcSet[sc.dc]:
            return err[DynamicImage](decodingError("jpeg: missing Huffman table"))
      else:
        for sc in scanComps:
          if not acSet[sc.ac]:
            return err[DynamicImage](decodingError("jpeg: missing Huffman table"))
      for i in 0..<comps.len:
        if not qtsSet[comps[i].tq]:
          return err[DynamicImage](decodingError("jpeg: missing quant table"))
      # per-coefficient continuity: a first scan (ah == 0) must cover only
      # fresh positions; a refinement must cover positions all coded at
      # exactly ah, stepping down to ah - 1.
      if ah == 0:
        for sc in scanComps:
          let ci = sc.comp
          for k in ss..se:
            if coefAl[ci][k] >= 0:
              return err[DynamicImage](decodingError("jpeg: band recoded"))
          for k in ss..se: coefAl[ci][k] = al
      else:
        if al != ah - 1:
          return err[DynamicImage](decodingError("jpeg: bad approximation"))
        for sc in scanComps:
          let ci = sc.comp
          for k in ss..se:
            if coefAl[ci][k] != ah:
              return err[DynamicImage](decodingError("jpeg: bad band refine"))
          for k in ss..se: coefAl[ci][k] = al
      pos += segLen - 2
      when defined(decodeProfile):
        let tProfScan0 = cpuTime()
      let (cleanS, nextPos) = buildCleanScan(pos)
      var reader = BitReader(data: cleanS, pos: 0, buf: 0, nbits: 0)
      for i in 0..<comps.len: comps[i].dcPred = 0
      var eobrun = 0
      let isDc = ss == 0 and se == 0
      let isFirst = ah == 0
      # Non-interleaved scans visit one block per MCU in plain raster order
      # over the component's block grid (T.81: a single-component scan MCU
      # is a single block; libjpeg-turbo jdinput.c per_scan_setup,
      # zune-jpeg parse_*_non_interleaved). Emulate with 1x1 effective
      # blocks; the formulas below then yield blk == mcuIdx.
      let nonInter = scanComps.len == 1
      var totalMcus = pMcuX * pMcuY
      if nonInter:
        totalMcus = pcoef[scanComps[0].comp].len
      var mcuIdx = 0
      var scanErr = ""
      while mcuIdx < totalMcus and scanErr == "":
        for sc in scanComps:
          let ci = sc.comp
          let bh = if nonInter: 1 else: comps[ci].h
          let bv = if nonInter: 1 else: comps[ci].v
          let emx = if nonInter: pMcuX * comps[ci].h else: pMcuX
          let nb = bh * bv
          let cols = emx * bh
          for b in 0..<nb:
            let bx = (mcuIdx mod emx) * bh + (b mod bh)
            let by = (mcuIdx div emx) * bv + (b div bv)
            let blk = by * cols + bx
            if isDc:
              if isFirst:
                let (okD, sym) = decodeHuff(reader, dcTables[sc.dc])
                if not okD: scanErr = "jpeg: bad DC code"; break
                let (okV, diff) = receiveExtend(reader, sym)
                if not okV: scanErr = "jpeg: truncated DC"; break
                comps[ci].dcPred += diff
                pcoef[ci][blk][0] = int32(comps[ci].dcPred shl al)
              else:
                let (okB, bit) = reader.readBits(1)
                if not okB: scanErr = "jpeg: truncated DC refine"; break
                pcoef[ci][blk][0] += int32(bit shl al)
            else:
              if eobrun > 0:
                dec(eobrun)
                if not isFirst:
                  for k in ss..se:
                    let p = Unzigzag[k]
                    if pcoef[ci][blk][p] != 0:
                      let (okB, bit) = reader.readBits(1)
                      if not okB: scanErr = "jpeg: truncated AC refine"; break
                      if bit == 1 and (pcoef[ci][blk][p] and int32(1 shl al)) == 0:
                        if pcoef[ci][blk][p] > 0:
                          pcoef[ci][blk][p] += int32(bit shl al)
                        else:
                          pcoef[ci][blk][p] -= int32(bit shl al)
                  if scanErr != "": break
                continue
              var k = ss
              var done = false
              while k <= se and not done:
                let (okA, rs) = decodeHuff(reader, acTables[sc.ac])
                if not okA:
                  when defined(progDebug):
                    scanErr = "jpeg: bad AC code mcu=" & $mcuIdx & " b=" & $b & " k=" & $k
                  else:
                    scanErr = "jpeg: bad AC code"
                  break
                let r = rs shr 4; let s = rs and 15
                if isFirst:
                  if s == 0:
                    if r == 15: k += 16
                    else:
                      eobrun = (1 shl r) - 1
                      if r > 0:
                        let (okE, e) = reader.readBits(r)
                        if not okE: scanErr = "jpeg: truncated EOB"; break
                        eobrun += e
                      done = true
                  else:
                    # NOTE: encoders emit coefficients past the declared band
                    # end (e.g. band 1-5 holding a coeff at zigzag 6); like
                    # zune-jpeg, store it (clamped to the block).
                    k += r
                    let (okC, v) = receiveExtend(reader, s)
                    if not okC: scanErr = "jpeg: truncated AC"; break
                    pcoef[ci][blk][Unzigzag[min(k, 63)]] = int32(v shl al)
                    inc(k)
                else:
                  if s == 0:
                    if r == 15:
                      # ZRL: 16 zeros; significant coeffs passed over are
                      # refined but NOT counted toward the 16.
                      var zeros = 0
                      while zeros < 16:
                        if k > se: break
                        let p = Unzigzag[k]
                        if pcoef[ci][blk][p] != 0:
                          let (okB, bit) = reader.readBits(1)
                          if not okB: scanErr = "jpeg: truncated AC refine"; break
                          if bit == 1 and (pcoef[ci][blk][p] and int32(1 shl al)) == 0:
                            if pcoef[ci][blk][p] > 0:
                              pcoef[ci][blk][p] += int32(bit shl al)
                            else:
                              pcoef[ci][blk][p] -= int32(bit shl al)
                        else: inc(zeros)
                        inc(k)
                      if scanErr != "": break
                    else:
                      eobrun = (1 shl r) - 1
                      if r > 0:
                        let (okE, e) = reader.readBits(r)
                        if not okE: scanErr = "jpeg: truncated EOB"; break
                        eobrun += e
                      while k <= se:
                        let p = Unzigzag[k]
                        if pcoef[ci][blk][p] != 0:
                          let (okB, bit) = reader.readBits(1)
                          if not okB: scanErr = "jpeg: truncated AC refine"; break
                          if bit == 1 and (pcoef[ci][blk][p] and int32(1 shl al)) == 0:
                            if pcoef[ci][blk][p] > 0:
                              pcoef[ci][blk][p] += int32(bit shl al)
                            else:
                              pcoef[ci][blk][p] -= int32(bit shl al)
                        inc(k)
                      if scanErr != "": break
                      done = true
                  elif s == 1:
                    # newly significant at this bit plane; the sign bit comes
                    # immediately after the symbol (libjpeg-turbo jdphuff.c,
                    # zune-jpeg bitstream.rs), BEFORE the skipped-coeff
                    # refinement bits. r counts zeros; significant coeffs
                    # passed over are refined, not counted.
                    # k is capped at the band end like zune-jpeg.
                    let (okS, sb) = reader.readBits(1)
                    if not okS: scanErr = "jpeg: truncated AC"; break
                    let nv = if sb == 1: 1 shl al else: -(1 shl al)
                    # Turbo do-while: always process k first; nonzero coeffs
                    # are refined without counting toward r, zeros count
                    # down, stop at the (r+1)-th zero. (A plain
                    # `while zeros < r` loop skips refinement entirely when
                    # r == 0 and the current coeff is already significant.)
                    var rr = r
                    while true:
                      if k > se: break
                      let p = Unzigzag[k]
                      if pcoef[ci][blk][p] != 0:
                        let (okB, bit) = reader.readBits(1)
                        if not okB: scanErr = "jpeg: truncated AC refine"; break
                        if bit == 1 and (pcoef[ci][blk][p] and int32(1 shl al)) == 0:
                          if pcoef[ci][blk][p] > 0:
                            pcoef[ci][blk][p] += int32(bit shl al)
                          else:
                            pcoef[ci][blk][p] -= int32(bit shl al)
                      else:
                        if rr == 0: break
                        dec(rr)
                      inc(k)
                    if scanErr != "": break
                    let kk = min(k, se)
                    pcoef[ci][blk][Unzigzag[kk]] = int32(nv)
                    k = kk + 1
                  else:
                    scanErr = "jpeg: bad AC refine symbol"; break
            if scanErr != "": break
          if scanErr != "": break
        inc(mcuIdx)
        if restartInterval > 0 and mcuIdx mod restartInterval == 0:
          for i in 0..<comps.len: comps[i].dcPred = 0
          eobrun = 0
      if scanErr != "":
        when defined(progDebug):
          echo "scan ", scanCount, " ss=", ss, " se=", se, " err=", scanErr
        return err[DynamicImage](decodingError(scanErr))
      inc(scanCount)
      when defined(progDebug):
        echo "scan ", scanCount, " done ss=", ss, " se=", se, " al=", al, " pos=", pos, "->", nextPos
      pos = nextPos
      when defined(decodeProfile):
        tProfEntropy += cpuTime() - tProfScan0
      continue
    else:
      if m >= 0xC0 and m <= 0xCF:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jpeg: SOF marker " & $m))
      discard
    pos += segLen - 2
  # Build cleaned entropy stream: strip RSTn, stop at next marker.
  # (progressive finish needs no BitReader; blocks come from pcoef.)
  var reader = BitReader(data: @[], pos: 0, buf: 0, nbits: 0)
  if not progFinish:
    let (clean, _) = buildCleanScan(scanStart)
    reader = BitReader(data: clean, pos: 0, buf: 0, nbits: 0)
  var maxH = 1; var maxV = 1
  for i in 0..<comps.len:
    maxH = max(maxH, comps[i].h); maxV = max(maxV, comps[i].v)
  when defined(decodeProfile):
    echo "decodeProfile afterEntropy peak=", peakMb(), "MB"
  let blk = 8 div denom # scaled block edge (8/4/2/1)
  let outW = (width + denom - 1) div denom
  let outH = (height + denom - 1) div denom
  let mcuW = 8 * maxH; let mcuH = 8 * maxV
  let mcuCountX = (width + mcuW - 1) div mcuW
  let mcuCountY = (height + mcuH - 1) div mcuH
  for i in 0..<comps.len:
    comps[i].blocks = newPixBlocks(
      mcuCountX * comps[i].h * mcuCountY * comps[i].v)
  var coef: array[64, float64]
  let totalMcus = mcuCountX * mcuCountY
  var mcuIdx = 0
  if progFinish:
    # progressive: dequant accumulated coefficients, IDCT every block
    when defined(decodeProfile):
      let tProfIdct0 = cpuTime()
    for ci in 0..<comps.len:
      for bi in 0..<comps[ci].blocks.len:
        for k in 0..63: coef[k] = float64(pcoef[ci][bi][k])
        comps[ci].blocks[bi] = idctScaledBlock(coef, qts[comps[ci].tq], blk)
    when defined(decodeProfile):
      tProfIdct += cpuTime() - tProfIdct0
    when defined(progDebug):
      for k in 0..63:
        echo "coef[", k, "]=", pcoef[0][0][k]
  else:
    when defined(decodeProfile):
      let tProfBase0 = cpuTime()
    while mcuIdx < totalMcus:
      for sc in scanComps:
        let ci = sc.comp
        let nb = comps[ci].h * comps[ci].v
        let cols = mcuCountX * comps[ci].h
        for b in 0..<nb:
          let (okD, sym) = decodeHuff(reader, dcTables[sc.dc])
          if not okD:
            return err[DynamicImage](decodingError("jpeg: bad DC code"))
          let (okV, diff) = receiveExtend(reader, sym)
          if not okV:
            return err[DynamicImage](decodingError("jpeg: truncated DC"))
          comps[ci].dcPred += diff
          for i in 0..63: coef[i] = 0.0
          coef[0] = float64(comps[ci].dcPred)
          var k = 1
          var eob = false
          while k < 64 and not eob:
            let (okA, rs) = decodeHuff(reader, acTables[sc.ac])
            if not okA:
              return err[DynamicImage](decodingError("jpeg: bad AC code"))
            let r = rs shr 4; let s = rs and 15
            if s == 0:
              if r == 15: k += 16
              else: eob = true
            else:
              k += r
              if k >= 64:
                return err[DynamicImage](decodingError("jpeg: AC overflow"))
              let (okC, v) = receiveExtend(reader, s)
              if not okC:
                return err[DynamicImage](decodingError("jpeg: truncated AC"))
              coef[Unzigzag[k]] = float64(v)
              inc(k)
          let bx = (mcuIdx mod mcuCountX) * comps[ci].h + (b mod comps[ci].h)
          let by = (mcuIdx div mcuCountX) * comps[ci].v + (b div comps[ci].h)
          comps[ci].blocks[by * cols + bx] =
            idctScaledBlock(coef, qts[comps[ci].tq], blk)
      inc(mcuIdx)
      if restartInterval > 0 and mcuIdx mod restartInterval == 0:
        for i in 0..<comps.len: comps[i].dcPred = 0
    when defined(decodeProfile):
      tProfIdct += cpuTime() - tProfBase0
  # assemble pixels with upsampling (replication)
  when defined(decodeProfile):
    let tProfAsm0 = cpuTime()
    echo "decodeProfile afterIdct peak=", peakMb(), "MB"
  if comps.len == 1:
    var px = newSeq[Luma[uint8]](outW * outH)
    let cols = mcuCountX * comps[0].h
    for y in 0..<outH:
      for x in 0..<outW:
        let bx = x div blk; let by = y div blk
        px[y*outW+x] = Luma[uint8](data: [comps[0].blocks[by*cols+bx][(y mod blk)*blk + (x mod blk)]])
    when defined(decodeProfile):
      tProfAsm += cpuTime() - tProfAsm0
      echo "decodeProfile entropy=", tProfEntropy, "s idct=", tProfIdct,
        "s asm=", tProfAsm, "s"
    return ok(DynamicImage(kind: dkLuma8, luma8:
      GrayImage(width: uint32(outW), height: uint32(outH), pixels: move(px))))
  elif comps.len == 3 or comps.len == 4:
    let isYcck = adobeTransform == 2
    var px = newSeq[Rgb[uint8]](outW * outH)
    when defined(decodeProfile):
      echo "decodeProfile afterPxAlloc peak=", peakMb(), "MB"
    if comps.len == 3:
      # 3-component fast path: hoist the runtime upsample divisions into
      # per-column maps, gather planar rows, convert whole rows via SIMD.
      var xmaps: array[3, seq[int]]
      for ci in 0..2:
        xmaps[ci] = newSeq[int](outW)
        for x in 0..<outW: xmaps[ci][x] = (x * comps[ci].h) div maxH
      var yRow = newSeq[uint8](outW)
      var cbRow = newSeq[uint8](outW)
      var crRow = newSeq[uint8](outW)
      let xm0 = xmaps[0]; let xm1 = xmaps[1]; let xm2 = xmaps[2]
      for y in 0..<outH:
        when defined(decodeProfile):
          let tProfG0 = cpuTime()
        for ci in 0..2:
          # NOTE: `let c = comps[ci]` is a compile error (PixBlocks is
          # non-copyable) — always index `comps[ci]` in place.
          let cols = mcuCountX * comps[ci].h
          let sy = (y * comps[ci].v) div maxV
          let by = sy div blk; let my = (sy mod blk) * blk
          var dst: ptr UncheckedArray[uint8]
          if ci == 0: dst = cast[ptr UncheckedArray[uint8]](addr yRow[0])
          elif ci == 1: dst = cast[ptr UncheckedArray[uint8]](addr cbRow[0])
          else: dst = cast[ptr UncheckedArray[uint8]](addr crRow[0])
          let xm = if ci == 0: xm0 elif ci == 1: xm1 else: xm2
          for x in 0..<outW:
            let sx = xm[x]
            dst[x] = comps[ci].blocks[by * cols + (sx div blk)][my + (sx mod blk)]
        when defined(decodeProfile):
          tProfGather += cpuTime() - tProfG0
          let tProfC0 = cpuTime()
        ycbcrRowSimd(addr yRow[0], addr cbRow[0], addr crRow[0],
          cast[ptr uint8](addr px[y*outW]), outW)
        when defined(decodeProfile):
          tProfConvert += cpuTime() - tProfC0
      when defined(decodeProfile):
        tProfAsm += cpuTime() - tProfAsm0
        echo "decodeProfile entropy=", tProfEntropy, "s idct=", tProfIdct,
          "s asm=", tProfAsm, "s gather=", tProfGather, "s convert=",
          tProfConvert, "s"
      return ok(DynamicImage(kind: dkRgb8, rgb8:
        RgbImage(width: uint32(outW), height: uint32(outH), pixels: move(px))))
    for y in 0..<outH:
      for x in 0..<outW:
        var samp: array[4, uint8]
        for ci in 0..<comps.len:
          # NOTE: no `let c` copy here (see above) — index in place.
          let sx = (x * comps[ci].h) div maxH
          let sy = (y * comps[ci].v) div maxV
          let cols = mcuCountX * comps[ci].h
          samp[ci] = comps[ci].blocks[(sy div blk) * cols + (sx div blk)][(sy mod blk)*blk + (sx mod blk)]
        var cc, mm, yy, kk: uint8
        if isYcck:
          let (r, g, b) = ycbcrToRgb(samp[0], samp[1], samp[2])
          cc = 255 - r; mm = 255 - g; yy = 255 - b; kk = samp[3]
        else:
          cc = 255 - samp[0]; mm = 255 - samp[1]
          yy = 255 - samp[2]; kk = 255 - samp[3]
        px[y*width+x] = Rgb[uint8](data: [
          uint8(255 - min(255, int(cc) + int(kk))),
          uint8(255 - min(255, int(mm) + int(kk))),
          uint8(255 - min(255, int(yy) + int(kk)))])
    when defined(decodeProfile):
      tProfAsm += cpuTime() - tProfAsm0
      echo "decodeProfile entropy=", tProfEntropy, "s idct=", tProfIdct,
        "s asm=", tProfAsm, "s"
    return ok(DynamicImage(kind: dkRgb8, rgb8:
      RgbImage(width: uint32(outW), height: uint32(outH), pixels: move(px))))
  err[DynamicImage](unsupportedError(ukGenericFeature, "jpeg: components"))
