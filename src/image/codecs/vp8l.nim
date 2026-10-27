## WebP codec — references/image/src/codecs/webp/ + image-webp@0.2.0
## VP8L lossless decode (meta-Huffman, LZ77, color cache, 4 transforms) +
## literal-only VP8L encoder. VP8 lossy keyframe decode (vp8.nim).
## Animation / ALPH-with-VP8 return Unsupported.
## Bitstream: LSB-first. Pixels in buffer order [R,G,B,A].
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic
import ./vp8

# ---------- LSB bit reader ----------

type LsbReader = object
  data: seq[uint8]
  pos: int
  buf: uint64
  nbits: int

proc fillBits(r: var LsbReader) =
  while r.nbits <= 56 and r.pos < r.data.len:
    r.buf = r.buf or (uint64(r.data[r.pos]) shl r.nbits)
    r.nbits += 8
    inc(r.pos)

proc peekBits(r: LsbReader, n: int): uint64 =
  if n == 64: r.buf
  elif n == 0: 0
  else: r.buf and ((1'u64 shl n) - 1)

proc readBits(r: var LsbReader, n: int): tuple[ok: bool, v: uint64] =
  if n == 0: return (true, 0)
  if r.nbits < n: r.fillBits()
  if r.nbits < n: return (false, 0)
  let v = r.peekBits(n)
  r.buf = r.buf shr n
  r.nbits -= n
  (true, v)

# ---------- canonical Huffman (LSB, libwebp-style) ----------

const
  MaxCodeLen = 15
  MaxTableBits = 10
  CodeLenOrder = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]

func rev16(code, length: int): int =
  var c = code
  var r = 0
  for _ in 0..<length:
    r = (r shl 1) or (c and 1)
    c = c shr 1
  r

type HuffNode = object
  isBranch: bool
  empty: bool
  offset: int
  symbol: uint16

type HuffTree = object
  single: bool
  singleSym: uint16
  table: seq[uint32]
  tableMask: int
  tree: seq[HuffNode]

proc buildImplicit(lengths: openArray[uint16]): tuple[ok: bool, t: HuffTree] =
  var hist: array[16, int]
  var numSym = 0
  for l in lengths:
    if l != 0:
      if int(l) > MaxCodeLen: return (false, HuffTree())
      hist[int(l)] += 1
      inc(numSym)
  if numSym == 0: return (false, HuffTree())
  if numSym == 1:
    var sym = 0
    for i, l in lengths:
      if l != 0: sym = i; break
    return (true, HuffTree(single: true, singleSym: uint16(sym)))
  var nextCodes: array[16, int]
  var code = 0
  var maxLen = 0
  for l in 1..15:
    if hist[l] > 0: maxLen = l
  for l in 1..maxLen:
    nextCodes[l] = code
    code = (code + hist[l]) shl 1
  if code != 2 shl maxLen: return (false, HuffTree())
  let tableBits = min(maxLen, MaxTableBits)
  let tableSize = 1 shl tableBits
  var table = newSeq[uint32](tableSize)
  var tree: seq[HuffNode] = @[]
  for sym, length in lengths:
    if length == 0: continue
    let l = int(length)
    let c = nextCodes[l]; inc(nextCodes[l])
    if l <= tableBits:
      var j = rev16(c, l)
      let entry = (uint32(l) shl 16) or uint32(sym)
      while j < tableSize:
        table[j] = entry
        j += 1 shl l
    else:
      let ti = rev16(c, l) and (tableSize - 1)
      if (table[ti] shr 16) != 0:
        return (false, HuffTree()) # primary slot already a leaf
      var nodeIdx =
        if table[ti] == 0:
          let ni = tree.len
          table[ti] = uint32(ni + 1)
          tree.add(HuffNode(empty: true))
          ni
        else:
          int(table[ti]) - 1
      for depth in countdown(l - tableBits - 1, 0):
        let bit = (c shr depth) and 1
        if tree[nodeIdx].empty:
          let off = tree.len - nodeIdx
          tree[nodeIdx].isBranch = true
          tree[nodeIdx].empty = false
          tree[nodeIdx].offset = off
          tree.add(HuffNode(empty: true)); tree.add(HuffNode(empty: true))
        elif not tree[nodeIdx].isBranch:
          return (false, HuffTree()) # occupied leaf
        nodeIdx += tree[nodeIdx].offset + bit
      if not tree[nodeIdx].empty:
        return (false, HuffTree())
      tree[nodeIdx].isBranch = false
      tree[nodeIdx].empty = false
      tree[nodeIdx].symbol = uint16(sym)
  (true, HuffTree(single: false, table: table, tableMask: tableSize - 1, tree: tree))

proc buildSingle(sym: uint16): HuffTree =
  HuffTree(single: true, singleSym: sym)

proc buildTwo(zero, one: uint16): HuffTree =
  HuffTree(single: false, table: @[(uint32(1) shl 16) or zero, (uint32(1) shl 16) or one],
    tableMask: 1, tree: @[])

proc readSymbol(r: var LsbReader, t: HuffTree): tuple[ok: bool, sym: uint16] =
  if t.single: return (true, t.singleSym)
  if r.nbits < 15: r.fillBits()
  let v = int(r.peekBits(16))
  let entry = t.table[v and t.tableMask]
  let ln = int(entry shr 16)
  if ln != 0:
    if r.nbits < ln: return (false, 0)
    r.buf = r.buf shr ln; r.nbits -= ln
    return (true, uint16(entry and 0xFFFF))
  # slow path
  var idx = int(entry and 0xFFFF) - 1
  var vv = v shr MaxTableBits
  var depth = MaxTableBits
  while true:
    if idx < 0 or idx >= t.tree.len: return (false, 0)
    let node = t.tree[idx]
    if not node.isBranch:
      if r.nbits < depth: return (false, 0)
      r.buf = r.buf shr depth; r.nbits -= depth
      return (true, node.symbol)
    idx += node.offset + (vv and 1)
    vv = vv shr 1
    inc(depth)

proc peekSymbol(t: HuffTree, r: LsbReader): tuple[hit: bool, ln: int, sym: uint16] =
  if t.single: return (true, 0, t.singleSym)
  let v = int(r.peekBits(16))
  let entry = t.table[v and t.tableMask]
  if int(entry shr 16) != 0:
    (true, int(entry shr 16), uint16(entry and 0xFFFF))
  else:
    (false, 0, 0)

# ---------- transforms ----------

func avg2(a, b: uint8): uint8 = uint8((uint16(a) + uint16(b)) div 2)

func clampFull(a, b, c: int): uint8 = uint8(clamp(a + b - c, 0, 255))
func clampHalf(a, b: int): uint8 = uint8(clamp(a + (a - b) div 2, 0, 255))

func colorDelta(t, c: int8): uint32 =
  cast[uint32](int32(t) * int32(c)) shr 5

proc predMode(data: var seq[uint8], mode: int, s, e, w: int) =
  case mode
  of 0:
    var i = s + 3
    while i < e:
      data[i] = data[i] + 0xFF; i += 4
  of 1:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    var i = s
    while i < e:
      for k in 0..3:
        let v = data[i+k] + prev[k]; data[i+k] = v; prev[k] = v
      i += 4
  of 2:
    for i in s..<e: data[i] = data[i] + data[i - w*4]
  of 3:
    for i in s..<e: data[i] = data[i] + data[i - w*4 + 4]
  of 4:
    for i in s..<e: data[i] = data[i] + data[i - w*4 - 4]
  of 5:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tr = i - stride + 4; let tt = i - stride
      for k in 0..3:
        let v = data[i+k] + avg2(avg2(prev[k], data[tr+k]), data[tt+k])
        data[i+k] = v; prev[k] = v
      i += 4
  of 6:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tl = i - stride - 4
      for k in 0..3:
        let v = data[i+k] + avg2(prev[k], data[tl+k])
        data[i+k] = v; prev[k] = v
      i += 4
  of 7:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tt = i - stride
      for k in 0..3:
        let v = data[i+k] + avg2(prev[k], data[tt+k])
        data[i+k] = v; prev[k] = v
      i += 4
  of 8:
    let stride = w * 4
    for i in s..<e:
      data[i] = data[i] + avg2(data[i-stride-4], data[i-stride])
  of 9:
    let stride = w * 4
    for i in s..<e:
      data[i] = data[i] + avg2(data[i-stride], data[i-stride+4])
  of 10:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tl = i - stride - 4; let tt = i - stride; let tr = i - stride + 4
      for k in 0..3:
        let v = data[i+k] + avg2(avg2(prev[k], data[tl+k]), avg2(data[tt+k], data[tr+k]))
        data[i+k] = v; prev[k] = v
      i += 4
  of 11:
    var l = [int16(data[s-4]), int16(data[s-3]), int16(data[s-2]), int16(data[s-1])]
    var tl = [int16(data[s-w*4-4]), int16(data[s-w*4-3]), int16(data[s-w*4-2]), int16(data[s-w*4-1])]
    let stride = w * 4
    var i = s
    while i < e:
      let tt = i - stride
      var pl = 0; var pt = 0
      var tarr = [int16(data[tt]), int16(data[tt+1]), int16(data[tt+2]), int16(data[tt+3])]
      for k in 0..3:
        let pr = l[k] + tarr[k] - tl[k]
        pl += abs(pr - l[k]); pt += abs(pr - tarr[k])
      if pl < pt:
        for k in 0..3:
          let v = data[i+k] + uint8(l[k]); data[i+k] = v
      else:
        for k in 0..3:
          let v = data[i+k] + uint8(tarr[k]); data[i+k] = v
      tl = tarr
      l = [int16(data[i]), int16(data[i+1]), int16(data[i+2]), int16(data[i+3])]
      i += 4
  of 12:
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tl = i - stride - 4; let tt = i - stride
      for k in 0..3:
        let v = data[i+k] + clampFull(int(prev[k]), int(data[tt+k]), int(data[tl+k]))
        data[i+k] = v; prev[k] = v
      i += 4
  else: # 13
    var prev = [data[s-4], data[s-3], data[s-2], data[s-1]]
    let stride = w * 4
    var i = s
    while i < e:
      let tl = i - stride - 4; let tt = i - stride
      for k in 0..3:
        let v = data[i+k] + clampHalf((int(prev[k]) + int(data[tt+k])) div 2, int(data[tl+k]))
        data[i+k] = v; prev[k] = v
      i += 4

const DistMap: array[120, tuple[dx, dy: int]] = [
  (0,1),(1,0),(1,1),(-1,1),(0,2),(2,0),(1,2),(-1,2),(2,1),(-2,1),(2,2),(-2,2),
  (0,3),(3,0),(1,3),(-1,3),(3,1),(-3,1),(2,3),(-2,3),(3,2),(-3,2),(0,4),(4,0),
  (1,4),(-1,4),(4,1),(-4,1),(3,3),(-3,3),(2,4),(-2,4),(4,2),(-4,2),(0,5),(3,4),
  (-3,4),(4,3),(-4,3),(5,0),(1,5),(-1,5),(5,1),(-5,1),(2,5),(-2,5),(5,2),(-5,2),
  (4,4),(-4,4),(3,5),(-3,5),(5,3),(-5,3),(0,6),(6,0),(1,6),(-1,6),(6,1),(-6,1),
  (2,6),(-2,6),(6,2),(-6,2),(4,5),(-4,5),(5,4),(-5,4),(3,6),(-3,6),(6,3),(-6,3),
  (0,7),(7,0),(1,7),(-1,7),(5,5),(-5,5),(7,1),(-7,1),(4,6),(-4,6),(6,4),(-6,4),
  (2,7),(-2,7),(7,2),(-7,2),(3,7),(-3,7),(7,3),(-7,3),(5,6),(-5,6),(6,5),(-6,5),
  (8,0),(4,7),(-4,7),(7,4),(-7,4),(8,1),(8,2),(6,6),(-6,6),(8,3),(5,7),(-5,7),
  (7,5),(-7,5),(8,4),(6,7),(-6,7),(7,6),(-7,6),(8,5),(7,7),(-7,7),(8,6),(8,7)]

proc planeDist(xsize: int, code: int): int =
  if code > 120: code - 120
  else:
    let (dx, dy) = DistMap[code - 1]
    let d = dx + dy * xsize
    if d < 1: 1 else: d

proc copyDist(prefix: int, r: var LsbReader): tuple[ok: bool, n: int] =
  if prefix < 4: return (true, prefix + 1)
  let extra = (prefix - 2) shr 1
  let offset = (2 + (prefix and 1)) shl extra
  let (ok, bits) = r.readBits(extra)
  if not ok: return (false, 0)
  (true, offset + int(bits) + 1)

# ---------- VP8L decoder ----------

type Vp8lHuffGroup = array[5, HuffTree]

type Vp8lDecoder = object
  r: LsbReader
  width, height: int

proc subSize(size, bits: int): int = (size + (1 shl bits) - 1) shr bits

proc readCodeLengths(r: var LsbReader, numSyms: int): tuple[ok: bool, lens: seq[uint16]] =
  var clLens = newSeq[uint16](19)
  let (okN, n) = r.readBits(4)
  if not okN: return (false, @[])
  let numCodes = int(n) + 4
  for i in 0..<numCodes:
    let (ok, v) = r.readBits(3)
    if not ok: return (false, @[])
    clLens[CodeLenOrder[i]] = uint16(v)
  let (okT, tt) = buildImplicit(clLens)
  if not okT: return (false, @[])
  let (okM, hasMax) = r.readBits(1)
  if not okM: return (false, @[])
  var maxSym = numSyms
  if hasMax == 1:
    let (okL, lb) = r.readBits(3)
    if not okL: return (false, @[])
    let lenBits = 2 + 2 * int(lb)
    let (okMx, mm) = r.readBits(lenBits)
    if not okMx: return (false, @[])
    if int(mm) > numSyms - 2: return (false, @[])
    maxSym = 2 + int(mm)
  var lens = newSeq[uint16](numSyms)
  var prev = 8'u16
  var sym = 0
  var left = maxSym
  while sym < numSyms:
    if left == 0: break
    dec(left)
    let (ok, cl) = readSymbol(r, tt)
    if not ok: return (false, @[])
    if cl < 16:
      lens[sym] = cl
      inc(sym)
      if cl != 0: prev = cl
    else:
      let slot = int(cl) - 16
      let extraBits = [2, 3, 7][slot]
      let repOff = [3, 3, 11][slot]
      let (okR, rr) = r.readBits(extraBits)
      if not okR: return (false, @[])
      var rep = int(rr) + repOff
      if sym + rep > numSyms: return (false, @[])
      let fill = if cl == 16: prev else: 0'u16
      while rep > 0:
        lens[sym] = fill
        inc(sym); dec(rep)
  (true, lens)

proc readHuffTree(r: var LsbReader, alphabet: int): tuple[ok: bool, t: HuffTree] =
  let (okS, simple) = r.readBits(1)
  if not okS: return (false, HuffTree())
  if simple == 1:
    let (okN, nn) = r.readBits(1)
    if not okN: return (false, HuffTree())
    let (ok8, is8) = r.readBits(1)
    if not ok8: return (false, HuffTree())
    let (okZ, z) = r.readBits(1 + 7 * int(is8))
    if not okZ or int(z) >= alphabet: return (false, HuffTree())
    if nn == 0:
      return (true, buildSingle(uint16(z)))
    let (okO, o) = r.readBits(8)
    if not okO or int(o) >= alphabet: return (false, HuffTree())
    return (true, buildTwo(uint16(z), uint16(o)))
  let (okL, lens) = readCodeLengths(r, alphabet)
  if not okL: return (false, HuffTree())
  buildImplicit(lens)

type HuffInfo = object
  xsize: int
  bits: int
  mask: int
  image: seq[uint16]
  groups: seq[Vp8lHuffGroup]
  cacheBits: int
  cache: seq[array[4, uint8]]

proc cacheInsert(info: var HuffInfo, c: array[4, uint8]) =
  if info.cacheBits == 0: return
  let u = (uint32(c[0]) shl 16) or (uint32(c[1]) shl 8) or uint32(c[2]) or
    (uint32(c[3]) shl 24)
  let idx = int((0x1E35A7BD'u32 * u) shr (32 - info.cacheBits))
  info.cache[idx] = c

proc decodeStream(r: var LsbReader, xsize, ysize: int, isArgb: bool,
    data: var seq[uint8]): tuple[ok: bool, info: HuffInfo] =
  var info: HuffInfo
  let (okC, useCache) = r.readBits(1)
  if not okC: return (false, info)
  if useCache == 1:
    let (okB, cb) = r.readBits(4)
    if not okB or cb < 1 or cb > 11: return (false, info)
    info.cacheBits = int(cb)
    info.cache = newSeq[array[4, uint8]](1 shl info.cacheBits)
  # meta huffman?
  var numGroups = 1
  if isArgb:
    let (okM, meta) = r.readBits(1)
    if not okM: return (false, info)
    if meta == 1:
      let (okB, hb) = r.readBits(3)
      if not okB: return (false, info)
      info.bits = int(hb) + 2
      let hx = subSize(xsize, info.bits)
      let hy = subSize(ysize, info.bits)
      var metaPix = newSeq[uint8](hx * hy * 4)
      let (_, sub) = decodeStream(r, hx, hy, false, metaPix)
      info.image = newSeq[uint16](hx * hy)
      for i in 0..<hx*hy:
        let code = uint16(metaPix[4*i]) shl 8 or uint16(metaPix[4*i+1])
        info.image[i] = code
        if int(code) + 1 > numGroups: numGroups = int(code) + 1
      info.xsize = hx
      info.mask = (1 shl info.bits) - 1
  if info.bits == 0:
    info.mask = high(int)
  for _ in 0..<numGroups:
    var g: Vp8lHuffGroup
    var alphabets = [256 + 24, 256, 256, 256, 40]
    if info.cacheBits > 0: alphabets[0] += 1 shl info.cacheBits
    for j in 0..4:
      let (ok, t) = readHuffTree(r, alphabets[j])
      if not ok: return (false, info)
      g[j] = t
    info.groups.add(g)
  # pixel data
  let total = xsize * ysize
  var idx = 0
  data.setLen(total * 4)
  var nextBlock = 0
  var tree = info.groups[0]
  while idx < total:
    if idx >= nextBlock:
      let x = idx mod xsize; let y = idx div xsize
      nextBlock = min(xsize - 1, x or info.mask) + y * xsize + 1
      var hi = 0
      if info.bits != 0:
        hi = int(info.image[(y shr info.bits) * info.xsize + (x shr info.bits)])
      tree = info.groups[hi]
      # single-node fast path
      var allSingle = true
      for j in 0..3:
        if not tree[j].single: allSingle = false; break
      if allSingle:
        let (okG, cg) = readSymbol(r, tree[0])
        if not okG or int(cg) >= 256: return (false, info)
        let n = if info.bits == 0: total else: nextBlock - idx
        let (okR, cr) = readSymbol(r, tree[1])
        let (okB2, cb2) = readSymbol(r, tree[2])
        let (okA, ca) = readSymbol(r, tree[3])
        if not (okR and okB2 and okA): return (false, info)
        let px = [uint8(cr), uint8(cg), uint8(cb2), uint8(ca)]
        for i in 0..<n:
          for k in 0..3: data[(idx+i)*4+k] = px[k]
        cacheInsert(info, px)
        idx += n
        continue
    let (okG, cg) = readSymbol(r, tree[0])
    if not okG: return (false, info)
    if int(cg) < 256:
      let (okR, cr) = readSymbol(r, tree[1])
      let (okB2, cb2) = readSymbol(r, tree[2])
      if r.nbits < 15: r.fillBits()
      let (okA, ca) = readSymbol(r, tree[3])
      if not (okR and okB2 and okA): return (false, info)
      let px = [uint8(cr), uint8(cg), uint8(cb2), uint8(ca)]
      for k in 0..3: data[idx*4+k] = px[k]
      cacheInsert(info, px)
      inc(idx)
    elif int(cg) < 280:
      let (okL, ln) = copyDist(int(cg) - 256, r)
      if not okL: return (false, info)
      let (okD, ds) = readSymbol(r, tree[4])
      if not okD: return (false, info)
      let (okD2, dist) = copyDist(int(ds), r)
      if not okD2: return (false, info)
      var d =
        if dist > 120: dist - 120
        else:
          let (dx, dy) = DistMap[dist - 1]
          let dd = dx + dy * xsize
          if dd < 1: 1 else: dd
      if idx < d or total - idx < ln: return (false, info)
      if d == 1:
        let v0 = data[(idx-1)*4]; let v1 = data[(idx-1)*4+1]
        let v2 = data[(idx-1)*4+2]; let v3 = data[(idx-1)*4+3]
        for i in 0..<ln:
          data[(idx+i)*4]=v0; data[(idx+i)*4+1]=v1
          data[(idx+i)*4+2]=v2; data[(idx+i)*4+3]=v3
      else:
        for i in 0..<ln*4:
          data[idx*4+i] = data[idx*4+i-d*4]
        if info.cacheBits > 0:
          for pxi in 0..<ln:
            cacheInsert(info, [data[(idx+pxi)*4], data[(idx+pxi)*4+1],
              data[(idx+pxi)*4+2], data[(idx+pxi)*4+3]])
      idx += ln
    else:
      if info.cacheBits == 0: return (false, info)
      let col = info.cache[int(cg) - 280]
      for k in 0..3: data[idx*4+k] = col[k]
      inc(idx)
      if idx < nextBlock:
        let (hit, ln2, sym2) = peekSymbol(tree[0], r)
        if hit and int(sym2) >= 280:
          r.buf = r.buf shr ln2; r.nbits -= ln2
          let col2 = info.cache[int(sym2) - 280]
          for k in 0..3: data[idx*4+k] = col2[k]
          inc(idx)
  (true, info)

type Transform = object
  kind: int # 0 predictor, 1 color, 2 subgreen, 3 colorindex
  sizeBits: int
  data: seq[uint8]
  tableSize: int

proc decodeVp8l*(payload: seq[uint8], wantW, wantH: int): ImageResult[RgbaImage] =
  ## payload starts at the 0x2f signature byte.
  var r = LsbReader(data: payload, pos: 0, buf: 0, nbits: 0)
  let (okS, sig) = r.readBits(8)
  if not okS or sig != 0x2F:
    return err[RgbaImage](decodingError("webp: bad VP8L signature"))
  let (okW, ww) = r.readBits(14)
  let (okH, hh) = r.readBits(14)
  let (okA, alphaUsed) = r.readBits(1)
  let (okV, ver) = r.readBits(3)
  if not (okW and okH and okA and okV):
    return err[RgbaImage](decodingError("webp: truncated VP8L header"))
  let w = int(ww) + 1; let h = int(hh) + 1
  if ver != 0:
    return err[RgbaImage](decodingError("webp: bad VP8L version"))
  if (wantW > 0 and w != wantW) or (wantH > 0 and h != wantH):
    return err[RgbaImage](decodingError("webp: VP8L size mismatch"))
  # transforms
  var transforms: seq[Transform] = @[]
  var order: seq[int] = @[]
  var xsize = w
  while true:
    let (ok, b) = r.readBits(1)
    if not ok: return err[RgbaImage](decodingError("webp: truncated transform"))
    if b == 0: break
    let (okT, tv) = r.readBits(2)
    if not okT: return err[RgbaImage](decodingError("webp: truncated transform"))
    let t = int(tv)
    for prev in order:
      if prev == t:
        return err[RgbaImage](decodingError("webp: duplicate transform"))
    order.add(t)
    if t == 0 or t == 1:
      let (okB, sb) = r.readBits(3)
      if not okB: return err[RgbaImage](decodingError("webp: truncated size bits"))
      let sizeBits = int(sb) + 2
      let bx = subSize(xsize, sizeBits); let by = subSize(h, sizeBits)
      var td = newSeq[uint8](bx * by * 4)
      let (okD, _) = decodeStream(r, bx, by, false, td)
      if not okD: return err[RgbaImage](decodingError("webp: bad transform data"))
      transforms.add(Transform(kind: t, sizeBits: sizeBits, data: td))
    elif t == 2:
      transforms.add(Transform(kind: 2))
    elif t == 3:
      let (okC, cs) = r.readBits(8)
      if not okC: return err[RgbaImage](decodingError("webp: truncated colormap"))
      let tableSize = int(cs) + 1
      var cmap = newSeq[uint8](tableSize * 4)
      let (okD, _) = decodeStream(r, tableSize, 1, false, cmap)
      if not okD: return err[RgbaImage](decodingError("webp: bad colormap"))
      for i in 4..<cmap.len: cmap[i] = cmap[i] + cmap[i-4]
      let bits = if tableSize <= 2: 3 elif tableSize <= 4: 2 elif tableSize <= 16: 1 else: 0
      xsize = subSize(xsize, bits)
      transforms.add(Transform(kind: 3, data: cmap, tableSize: tableSize))
  var img = newSeq[uint8](xsize * h * 4)
  let (okD, _) = decodeStream(r, xsize, h, true, img)
  if not okD: return err[RgbaImage](decodingError("webp: bad image data"))
  # apply transforms in reverse
  var imgW = xsize
  var imgLen = img.len
  for oi in countdown(order.len - 1, 0):
    let ti = order[oi]
    var tr: Transform
    for t in transforms:
      if t.kind == ti: tr = t; break
    if tr.kind == 0:
      # predictor
      let bw = imgW
      # top-left alpha special + first row + first column
      img[3] = img[3] + 255
      predMode(img, 1, 4, bw * 4, bw)
      for y in 1..<h:
        for k in 0..3:
          img[y*bw*4+k] = img[y*bw*4+k] + img[(y-1)*bw*4+k]
      let bxs = subSize(imgW, tr.sizeBits)
      for y in 1..<h:
        for bx in 0..<bxs:
          let p = int(tr.data[((y shr tr.sizeBits) * bxs + bx) * 4 + 1])
          let s = (y * bw + max(bx shl tr.sizeBits, 1)) * 4
          let e = (y * bw + min((bx + 1) shl tr.sizeBits, bw)) * 4
          predMode(img, p, s, e, bw)
    elif tr.kind == 1:
      # color transform (port of apply_color_transform)
      let bw = imgW
      let bxs = subSize(bw, tr.sizeBits)
      for y in 0..<h:
        for bx in 0..<bxs:
          let bi = (y shr tr.sizeBits) * bxs + bx
          let r2b = cast[int8](tr.data[bi*4])
          let g2b = cast[int8](tr.data[bi*4+1])
          let g2r = cast[int8](tr.data[bi*4+2])
          let x0 = bx shl tr.sizeBits
          let x1 = min(x0 + (1 shl tr.sizeBits), bw)
          for x in x0..<x1:
            let i = (y * bw + x) * 4
            let g = int(img[i+1])
            var trr = int(img[i]) + int(colorDelta(g2r, cast[int8](uint8(g and 0xFF))))
            var tb = int(img[i+2]) + int(colorDelta(g2b, cast[int8](uint8(g and 0xFF))))
            tb += int(colorDelta(r2b, cast[int8](uint8(trr and 0xFF))))
            img[i] = uint8(trr and 0xFF)
            img[i+2] = uint8(tb and 0xFF)
    elif tr.kind == 2:
      for i in countup(0, imgLen - 1, 4):
        img[i] = img[i] + img[i+1]
        img[i+2] = img[i+2] + img[i+1]
    else:
      # color indexing
      imgW = w
      imgLen = w * h * 4
      let tableSize = tr.tableSize
      let cmap = tr.data
      if tableSize > 16:
        var tab = newSeq[array[4, uint8]](256)
        for i in 0..<min(256, tableSize):
          tab[i] = [cmap[4*i], cmap[4*i+1], cmap[4*i+2], cmap[4*i+3]]
        for i in 0..<w*h:
          let k = int(img[i*4+1])
          img[i*4]=tab[k][0]; img[i*4+1]=tab[k][1]
          img[i*4+2]=tab[k][2]; img[i*4+3]=tab[k][3]
      else:
        let widthBits = if tableSize <= 2: 3 elif tableSize <= 4: 2 else: 1
        let per = 1 shl widthBits
        let bpe = 8 div per
        let mask = (1 shl bpe) - 1
        # build expanded table: 256 entries of per pixels
        var tab = newSeq[uint8](256 * per * 4)
        for i in 0..255:
          for j in 0..<per:
            let k = (i shr (j * bpe)) and mask
            if k < tableSize:
              for c in 0..3: tab[(i*per+j)*4+c] = cmap[k*4+c]
        let idxW = (w + per - 1) div per
        let entrySize = 4 * per
        let finalSize = w * 4 - entrySize * (idxW - 1)
        # careful: img currently holds packed indices; expand in place from the end
        var need = w * h * 4
        if img.len < need: img.setLen(need)
        for y in countdown(h - 1, 0):
          for x in countdown(idxW - 1, 0):
            let txi = int(img[y*idxW*4 + x*4 + 1])
            let outOff = y * w * 4 + x * entrySize
            let sz = if x == idxW - 1: finalSize else: entrySize
            for k in 0..<sz: img[outOff+k] = tab[txi*entrySize+k]
  var px = newSeq[Rgba[uint8]](w * h)
  for i in 0..<w*h:
    px[i] = Rgba[uint8](data: [img[4*i], img[4*i+1], img[4*i+2], img[4*i+3]])
  ok(RgbaImage(width: uint32(w), height: uint32(h), pixels: px))

# ---------- RIFF container ----------

proc decodeWebp*(data: seq[uint8]): ImageResult[DynamicImage] =
  if data.len < 12 or data[0..3] != @[uint8('R'),uint8('I'),uint8('F'),uint8('F')] or
      data[8..11] != @[uint8('W'),uint8('E'),uint8('B'),uint8('P')]:
    return err[DynamicImage](decodingError("webp: bad RIFF"))
  var pos = 12
  var vp8l: seq[uint8] = @[]
  var vp8body: seq[uint8] = @[]
  var hasVp8 = false
  var hasAlph = false
  var hasAnim = false
  while pos + 8 <= data.len:
    let tag = data[pos..<pos+4]
    let size = int(uint32(data[pos+4]) or (uint32(data[pos+5]) shl 8) or
      (uint32(data[pos+6]) shl 16) or (uint32(data[pos+7]) shl 24))
    pos += 8
    if pos + size > data.len:
      return err[DynamicImage](decodingError("webp: truncated chunk"))
    let body = data[pos..<pos+size]
    if tag == @[uint8('V'),uint8('P'),uint8('8'),uint8('L')]:
      if vp8l.len == 0:
        vp8l = body
    elif tag == @[uint8('V'),uint8('P'),uint8('8'),uint8(' ')]:
      hasVp8 = true
      if vp8body.len == 0:
        vp8body = body
    elif tag == @[uint8('A'),uint8('L'),uint8('P'),uint8('H')]:
      hasAlph = true
    elif tag == @[uint8('V'),uint8('P'),uint8('8'),uint8('X')]:
      discard # canvas info; VP8/VP8L chunks follow inline
    elif tag == @[uint8('A'),uint8('N'),uint8('I'),uint8('M')] or
        tag == @[uint8('A'),uint8('N'),uint8('M'),uint8('F')]:
      hasAnim = true
    pos += size + (size and 1)
  if hasAnim:
    return err[DynamicImage](unsupportedError(ukGenericFeature, "webp: animation"))
  if vp8l.len > 0 and not hasVp8:
    let r = decodeVp8l(vp8l, 0, 0)
    if not r.ok: return err[DynamicImage](r.err)
    # alpha handling like the reference: has_alpha flag -> Rgba else Rgb
    var hasAlpha = false
    for p in r.value.pixels:
      if p.data[3] != 255: hasAlpha = true; break
    if hasAlpha:
      return ok(DynamicImage(kind: dkRgba8, rgba8: r.value))
    var rgb = newSeq[Rgb[uint8]](r.value.pixels.len)
    for i, p in r.value.pixels:
      rgb[i] = Rgb[uint8](data: [p.data[0], p.data[1], p.data[2]])
    return ok(DynamicImage(kind: dkRgb8, rgb8:
      RgbImage(width: r.value.width, height: r.value.height, pixels: rgb)))
  if hasVp8 and vp8body.len > 0:
    if hasAlph:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "webp: alpha with lossy VP8"))
    let fr = decodeVp8Frame(vp8body)
    if not fr.ok: return err[DynamicImage](fr.err)
    let rgb = vp8ToRgb(fr.value)
    var px = newSeq[Rgb[uint8]](fr.value.width * fr.value.height)
    for i in 0..<px.len:
      px[i] = Rgb[uint8](data: [rgb[3 * i], rgb[3 * i + 1], rgb[3 * i + 2]])
    return ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(
      width: uint32(fr.value.width), height: uint32(fr.value.height),
      pixels: px)))
  if hasVp8:
    return err[DynamicImage](decodingError("webp: missing VP8 data"))
  err[DynamicImage](decodingError("webp: no image chunk"))

# ---------- literal-only VP8L encoder ----------

proc buildLens(freqs: openArray[int], maxLen = 15): seq[uint16] =
  ## Simple package-merge-free Huffman lengths: two-queue method on sorted freqs.
  ## Falls back to fixed lengths if skewed beyond maxLen.
  var n = freqs.len
  var lens = newSeq[uint16](n)
  var present: seq[tuple[f, s: int]] = @[]
  for i, f in freqs:
    if f > 0: present.add((f, i))
  if present.len == 0:
    return lens
  if present.len == 1:
    lens[present[0].s] = 1
    return lens
  # classic Huffman via repeated min-pair merging (O(n^2), n <= 320: fine)
  type Node = tuple[freq: int, syms: seq[int], minSym: int]
  var nodes: seq[Node] = @[]
  for p in present: nodes.add((p.f, @[p.s], p.s))
  var depth = newSeq[int](n)
  while nodes.len > 1:
    var a = 0; var b = 1
    if nodes[b].freq < nodes[a].freq or
        (nodes[b].freq == nodes[a].freq and nodes[b].minSym < nodes[a].minSym):
      a = 1; b = 0
    for i in 2..<nodes.len:
      if nodes[i].freq < nodes[b].freq or
          (nodes[i].freq == nodes[b].freq and nodes[i].minSym < nodes[b].minSym):
        a = b; b = i
      elif nodes[i].freq < nodes[a].freq or
          (nodes[i].freq == nodes[a].freq and nodes[i].minSym < nodes[a].minSym):
        a = i
    for s in nodes[a].syms: depth[s] += 1
    for s in nodes[b].syms: depth[s] += 1
    let na = nodes[a]; let nb = nodes[b]
    let merged = (na.freq + nb.freq, na.syms & nb.syms, min(na.minSym, nb.minSym))
    if a > b: nodes.delete(a); nodes.delete(b)
    else: nodes.delete(b); nodes.delete(a)
    nodes.add(merged)
  var over = false
  for d in depth:
    if d > maxLen: over = true
  if over:
    # fall back: fixed 9-bit-ish lengths for present symbols is invalid;
    # use uniform length covering present count
    var k = 1
    while (1 shl k) < present.len: inc(k)
    for p in present: lens[p.s] = uint16(k)
    return lens
  for i in 0..<n: lens[i] = uint16(depth[i])
  lens

proc canonCodes(lens: openArray[uint16]): tuple[code: seq[int], ln: seq[int]] =
  ## Canonical MSB-first codes converted to LSB-first emission values.
  var code = newSeq[int](lens.len)
  var ln = newSeq[int](lens.len)
  var count: array[16, int]
  for l in lens:
    if l != 0: count[int(l)] += 1
  var start: array[16, int]
  var c = 0
  for l in 1..15:
    start[l] = c
    c = (c + count[l]) shl 1
  for i, l in lens:
    if l != 0:
      code[i] = rev16(start[int(l)], int(l))
      ln[i] = int(l)
      inc(start[int(l)])
  (code, ln)

type Vp8lBitWriter = object
  data: seq[uint8]
  buf: uint32
  nbits: int

proc emitBits(w: var Vp8lBitWriter, v, n: int) =
  w.buf = w.buf or (uint32(v) shl w.nbits)
  w.nbits += n
  while w.nbits >= 8:
    w.data.add(uint8(w.buf and 0xFF))
    w.buf = w.buf shr 8
    w.nbits -= 8

proc emitFlush(w: var Vp8lBitWriter) =
  if w.nbits > 0:
    w.data.add(uint8(w.buf and 0xFF))
    w.buf = 0; w.nbits = 0

proc writeCodeLengths(w: var Vp8lBitWriter, lens: openArray[uint16], numSyms: int) =
  ## Non-simple path, full range (max_symbol bit = 0).
  ## RLE the lengths: 16 = repeat prev 3..6 (+2 bits), 17 = zeros 3..10 (+3),
  ## 18 = zeros 11..138 (+7). Extra values stored inline after the code.
  var seq16: seq[int] = @[]
  var i = 0
  while i < numSyms:
    let v = int(lens[i])
    var run = 1
    while i + run < numSyms and int(lens[i+run]) == v: inc(run)
    if v != 0:
      var left = run
      while left >= 3:
        let take = min(left, 6)
        seq16.add(16); seq16.add(take - 3)
        i += take; left -= take
      for _ in 0..<left:
        seq16.add(v); inc(i)
    else:
      var left = run
      while left >= 11:
        let take = min(left, 138)
        seq16.add(18); seq16.add(take - 11)
        i += take; left -= take
      if left >= 3:
        seq16.add(17); seq16.add(left - 3)
        i += left
      else:
        for _ in 0..<left:
          seq16.add(0); inc(i)
  var freq = newSeq[int](19)
  var k = 0
  while k < seq16.len:
    let s = seq16[k]
    if s <= 18: freq[s] += 1
    if s == 16 or s == 17 or s == 18: k += 2
    else: k += 1
  let clLens = buildLens(freq)
  const Order = [17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]
  var lastUsed = 4
  for k in countdown(18, 4):
    if clLens[Order[k]] != 0:
      lastUsed = k + 1
      break
  w.emitBits(0, 1) # not simple
  w.emitBits(lastUsed - 4, 4)
  for k in 0..<lastUsed:
    w.emitBits(int(clLens[Order[k]]), 3)
  w.emitBits(0, 1) # use full range (no max_symbol)
  let (cc, cl) = canonCodes(clLens)
  var j = 0
  while j < seq16.len:
    let s = seq16[j]
    w.emitBits(cc[s], cl[s])
    if s == 16:
      w.emitBits(seq16[j+1], 2); j += 2
    elif s == 17:
      w.emitBits(seq16[j+1], 3); j += 2
    elif s == 18:
      w.emitBits(seq16[j+1], 7); j += 2
    else:
      j += 1

proc encodeVp8l*(img: RgbaImage): seq[uint8] =
  ## Literal-only VP8L encoder (no LZ77/transforms/cache). Valid output,
  ## larger than reference encoders.
  let w = int(img.width); let h = int(img.height)
  var w2: Vp8lBitWriter
  w2.data.add(0x2F)
  var hdr = uint32(w - 1) or (uint32(h - 1) shl 14)
  var hasAlpha = false
  for p in img.pixels:
    if p.data[3] != 255: hasAlpha = true; break
  if hasAlpha: hdr = hdr or (1'u32 shl 28)
  for k in 0..3: w2.data.add(uint8((hdr shr (8*k)) and 0xFF))
  w2.emitBits(0, 1) # transforms: none
  w2.emitBits(0, 1) # no meta huffman
  # frequency counts
  var fG = newSeq[int](280); var fR = newSeq[int](256)
  var fB = newSeq[int](256); var fA = newSeq[int](256)
  for p in img.pixels:
    fR[p.data[0]] += 1; fG[p.data[1]] += 1; fB[p.data[2]] += 1; fA[p.data[3]] += 1
  w2.emitBits(0, 1) # no color cache
  let lG = buildLens(fG); let lR = buildLens(fR)
  let lB = buildLens(fB); let lA = buildLens(fA)
  # write 5 trees: green(280), red, blue, alpha, dist(40 zeros -> single?)
  # distance tree unused: write simple single-node tree with symbol 0
  writeCodeLengths(w2, lG, 280)
  writeCodeLengths(w2, lR, 256)
  writeCodeLengths(w2, lB, 256)
  writeCodeLengths(w2, lA, 256)
  # dist tree: simple 1-symbol tree with symbol 0 (never used, literal-only).
  # Layout: simple=1, num=0 (one symbol), is8=0, zero=0 (a single bit).
  w2.emitBits(1, 1); w2.emitBits(0, 1); w2.emitBits(0, 1); w2.emitBits(0, 1)
  let (cG, nG) = canonCodes(lG); let (cR, nR) = canonCodes(lR)
  let (cB, nB) = canonCodes(lB); let (cA, nA) = canonCodes(lA)
  template isSingle(lens: openArray[uint16]): bool =
    block:
      var npresent = 0
      for l in lens:
        if l != 0: inc(npresent)
      npresent == 1
  # Single-symbol trees decode without consuming bits, so the encoder must
  # emit nothing for them either.
  let sG = isSingle(lG); let sR = isSingle(lR)
  let sB = isSingle(lB); let sA = isSingle(lA)
  for p in img.pixels:
    if not sG: w2.emitBits(cG[p.data[1]], nG[p.data[1]])
    if not sR: w2.emitBits(cR[p.data[0]], nR[p.data[0]])
    if not sB: w2.emitBits(cB[p.data[2]], nB[p.data[2]])
    if not sA: w2.emitBits(cA[p.data[3]], nA[p.data[3]])
  w2.emitFlush()
  w2.data

proc encodeWebp*(img: DynamicImage): ImageResult[seq[uint8]] =
  let rgba = img.toRgba8()
  let payload = encodeVp8l(rgba)
  var output = @[uint8('R'),uint8('I'),uint8('F'),uint8('F')]
  let total = 4 + 8 + payload.len
  let pad = payload.len and 1
  for k in 0..3: output.add(uint8(((total + pad) shr (8*k)) and 0xFF))
  output.add([uint8('W'),uint8('E'),uint8('B'),uint8('P')])
  output.add([uint8('V'),uint8('P'),uint8('8'),uint8('L')])
  let n = uint32(payload.len)
  for k in 0..3: output.add(uint8((n shr (8*k)) and 0xFF))
  for b in payload: output.add(b)
  if pad == 1: output.add(0)
  ok(output)
