## JPEG codec — references/image/src/codecs/jpeg/ + zune-jpeg/jpeg-encoder
## Pure Nim baseline DCT: SOI/APP/DQT/SOF0+SOF1(8-bit)/DHT/DRI/SOS/RST/EOI,
## Huffman, separable float IDCT, 4:4:4/4:2:2/4:2:0 (+general H/V replication),
## YCbCr/RGB/gray/CMYK-Adobe. Progressive (SOF2) returns Unsupported.
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic

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

# ---------- separable float DCT/IDCT via cosine table ----------

var CosT {.global.}: array[8, array[8, float64]]
var Cfac {.global.}: array[8, float64]

proc initCos() =
  for u in 0..7:
    Cfac[u] = if u == 0: 0.3535533905932738 else: 0.5 # 1/sqrt(8), 1/2
    for x in 0..7:
      CosT[u][x] = cos((2.0 * float64(x) + 1.0) * float64(u) * PI / 16.0)

initCos()

proc idctBlock(coef: array[64, float64], qt: array[64, int]): array[64, uint8] =
  var tmp: array[64, float64]
  for i in 0..63: tmp[i] = coef[i] * float64(qt[i])
  var mid: array[64, float64]
  for y in 0..7:
    for x in 0..7:
      var s = 0.0
      for u in 0..7: s += Cfac[u] * tmp[y*8+u] * CosT[u][x]
      mid[y*8+x] = s
  for y in 0..7:
    for x in 0..7:
      var s = 0.0
      for v in 0..7: s += Cfac[v] * mid[v*8+x] * CosT[v][y]
      result[y*8+x] = uint8(clamp(int(s + 128.5), 0, 255))

proc fdctBlock(px: array[64, float64]): array[64, float64] =
  var mid: array[64, float64]
  for v in 0..7:
    for x in 0..7:
      var s = 0.0
      for y in 0..7: s += px[y*8+x] * CosT[v][y]
      mid[v*8+x] = s * Cfac[v]
  for v in 0..7:
    for u in 0..7:
      var s = 0.0
      for x in 0..7: s += mid[v*8+x] * CosT[u][x]
      result[v*8+u] = s * Cfac[u]

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

# ---------- color conversion ----------

proc ycbcrToRgb(y, cb, cr: uint8): tuple[r, g, b: uint8] =
  let fY = float64(y); let fCb = float64(cb) - 128.0; let fCr = float64(cr) - 128.0
  (uint8(clamp(int(fY + 1.402 * fCr + 0.5), 0, 255)),
   uint8(clamp(int(fY - 0.344136 * fCb - 0.714136 * fCr + 0.5), 0, 255)),
   uint8(clamp(int(fY + 1.772 * fCb + 0.5), 0, 255)))

# ---------- frame structures ----------

type JpegComponent = object
  id: uint8
  h*, v*: int
  tq*: int
  dcPred*: int
  blocks*: seq[array[64, uint8]]

proc decodeJpeg*(data: seq[uint8]): ImageResult[DynamicImage] =
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
  template need(n: int): bool = pos + n <= data.len
  while scanStart < 0:
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
    of 0xC0, 0xC1:
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
          tq: int(body[6+3*i+2]), dcPred: 0, blocks: @[]))
      sofFound = true
    of 0xC2:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "jpeg: progressive not supported"))
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
      if ns != comps.len or body.len < 1 + ns * 2 + 3:
        return err[DynamicImage](decodingError("jpeg: bad SOS"))
      scanComps = @[]
      for i in 0..<ns:
        let cs = body[1+2*i]
        var ci = -1
        for k, c in comps:
          if c.id == cs: ci = k; break
        if ci < 0:
          return err[DynamicImage](decodingError("jpeg: SOS unknown component"))
        scanComps.add((ci, int(body[1+2*i+1] shr 4), int(body[1+2*i+1] and 15)))
      if int(body[1+ns*2]) != 0 or int(body[1+ns*2+1]) != 63 or
          body[1+ns*2+2] != 0:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jpeg: only baseline scans"))
      for sc in scanComps:
        if not dcSet[sc.dc] or not acSet[sc.ac]:
          return err[DynamicImage](decodingError("jpeg: missing Huffman table"))
      for c in comps:
        if not qtsSet[c.tq]:
          return err[DynamicImage](decodingError("jpeg: missing quant table"))
      pos += segLen - 2
      scanStart = pos
    else:
      if m >= 0xC0 and m <= 0xCF:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "jpeg: SOF marker " & $m))
      discard
    if scanStart < 0:
      pos += segLen - 2
  # Build cleaned entropy stream: strip RSTn, stop at next marker.
  var clean: seq[uint8] = @[]
  var qq = scanStart
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
  var reader = BitReader(data: clean, pos: 0, buf: 0, nbits: 0)
  var maxH = 1; var maxV = 1
  for c in comps:
    maxH = max(maxH, c.h); maxV = max(maxV, c.v)
  let mcuW = 8 * maxH; let mcuH = 8 * maxV
  let mcuCountX = (width + mcuW - 1) div mcuW
  let mcuCountY = (height + mcuH - 1) div mcuH
  for i in 0..<comps.len:
    comps[i].blocks = newSeq[array[64, uint8]](
      mcuCountX * comps[i].h * mcuCountY * comps[i].v)
  var coef: array[64, float64]
  let totalMcus = mcuCountX * mcuCountY
  var mcuIdx = 0
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
        comps[ci].blocks[by * cols + bx] = idctBlock(coef, qts[comps[ci].tq])
    inc(mcuIdx)
    if restartInterval > 0 and mcuIdx mod restartInterval == 0:
      for i in 0..<comps.len: comps[i].dcPred = 0
  # assemble pixels with upsampling (replication)
  if comps.len == 1:
    var px = newSeq[Luma[uint8]](width * height)
    let cols = mcuCountX * comps[0].h
    for y in 0..<height:
      for x in 0..<width:
        let bx = x div 8; let by = y div 8
        px[y*width+x] = Luma[uint8](data: [comps[0].blocks[by*cols+bx][(y mod 8)*8 + (x mod 8)]])
    return ok(DynamicImage(kind: dkLuma8, luma8:
      GrayImage(width: uint32(width), height: uint32(height), pixels: px)))
  elif comps.len == 3 or comps.len == 4:
    let isYcck = adobeTransform == 2
    var px = newSeq[Rgb[uint8]](width * height)
    for y in 0..<height:
      for x in 0..<width:
        var samp: array[4, uint8]
        for ci in 0..<comps.len:
          let c = comps[ci]
          let sx = (x * c.h) div maxH; let sy = (y * c.v) div maxV
          let cols = mcuCountX * c.h
          samp[ci] = c.blocks[(sy div 8) * cols + (sx div 8)][(sy mod 8)*8 + (sx mod 8)]
        if comps.len == 4:
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
        else:
          let (r, g, b) = ycbcrToRgb(samp[0], samp[1], samp[2])
          px[y*width+x] = Rgb[uint8](data: [r, g, b])
    return ok(DynamicImage(kind: dkRgb8, rgb8:
      RgbImage(width: uint32(width), height: uint32(height), pixels: px)))
  err[DynamicImage](unsupportedError(ukGenericFeature, "jpeg: components"))
