## OpenEXR codec — references/image/src/codecs/openexr.rs + exr@1.74.0
## Single-part scanline only (tiled/multipart/deep/PIZ/PXR24/B44/DWAA/B
## return Unsupported). NONE/RLE/ZIP/ZIPS + half/float/uint -> 32F images.
## RLE/ZIP pipeline per exrs: separate even/odd halves, delta samples,
## then RLE (neg=literal -c bytes, pos=repeat c+1) / zlib-deflate.
import std/sequtils
import ../color
import ../error
import ../buffer
import ../dynamic
import ../zlibwrap

const ExrMagic* = [0x76'u8, 0x2F, 0x31, 0x01]

proc halfToFloat*(h: uint16): float32 =
  let s = (h shr 15) and 1
  let e = (h shr 10) and 0x1F
  let m = h and 0x3FF
  if e == 0:
    if m == 0:
      return if s == 1: -0.0'f32 else: 0.0'f32
    return (if s == 1: -1.0'f32 else: 1.0'f32) *
      float32(m) / 1024.0'f32 * 5.960464477539063e-08'f32
  elif e == 31:
    if m == 0:
      return cast[float32](if s == 1: 0xFF800000'u32 else: 0x7F800000'u32)
    return cast[float32](0x7FC00000'u32) # NaN
  let bits = (uint32(s) shl 31) or (uint32(int(e) + 112) shl 23) or
    (uint32(m) shl 13)
  cast[float32](bits)

proc floatToHalf*(f: float32): uint16 =
  let x = cast[uint32](f)
  let sign = uint16((x shr 16) and 0x8000)
  let xe = x and 0x7FFFFFFF'u32
  if (x and 0x7FFFFFFF'u32) > 0x7F800000'u32:
    return sign or 0x7E00'u16 # NaN
  if xe >= 0x47800000'u32:
    return sign or 0x7BFF'u16 # overflow -> max finite
  elif xe >= 0x38800000'u32:
    return sign or uint16(((xe - 0x38000000'u32) shr 13) and 0xFFFF)
  elif xe >= 0x33800000'u32:
    let e = int(xe shr 23)
    let m = (xe and 0x7FFFFF'u32) or 0x800000'u32
    let shift = 126 - e
    let t = (m + (1'u32 shl (shift - 1))) shr shift
    return sign or uint16(t and 0xFFFF)
  else:
    sign # underflow -> signed zero

# ---------- whole-buffer interleave + delta steps (exrs optimize_bytes) ----------

proc separateHalves(data: var seq[uint8]) =
  ## Even indices -> first half, odd -> second half (in place via copy).
  let n = data.len
  var tmp = newSeq[uint8](n)
  var j = 0
  var i = 0
  while i < n: tmp[j] = data[i]; inc(j); i += 2
  i = 1
  while i < n: tmp[j] = data[i]; inc(j); i += 2
  data = tmp

proc interleaveHalves(data: var seq[uint8]) =
  let n = data.len
  let half = (n + 1) div 2
  var tmp = newSeq[uint8](n)
  for i in 0..<n div 2:
    tmp[2*i] = data[i]
    tmp[2*i+1] = data[half+i]
  if n mod 2 == 1: tmp[n-1] = data[half-1]
  data = tmp

proc samplesToDifferences(data: var seq[uint8]) =
  if data.len == 0: return
  var prev = data[0]
  for i in 1..<data.len:
    let t = data[i]
    data[i] = t - prev # uint8 wraps mod 256
    prev = t

proc differencesToSamples(data: var seq[uint8]) =
  if data.len == 0: return
  for i in 1..<data.len:
    data[i] = data[i] + data[i-1] # uint8 wraps mod 256

# ---------- RLE (exrs compression::rle) ----------

proc rleDecompress(data: openArray[uint8], expected: int): ImageResult[seq[uint8]] =
  var output: seq[uint8] = @[]
  var i = 0
  while i < data.len and output.len != expected:
    let count = cast[int8](data[i]); inc(i)
    if count < 0:
      let k = int(-count)
      if i + k > data.len:
        return err[seq[uint8]](decodingError("exr: truncated RLE literal"))
      for j in 0..<k: output.add(data[i+j])
      i += k
    else:
      if i >= data.len:
        return err[seq[uint8]](decodingError("exr: truncated RLE run"))
      let v = data[i]; inc(i)
      for _ in 0..int(count): output.add(v)
  if output.len != expected:
    return err[seq[uint8]](decodingError("exr: RLE size mismatch"))
  differencesToSamples(output)
  interleaveHalves(output)
  if output.len != expected:
    return err[seq[uint8]](decodingError("exr: RLE size mismatch"))
  ok(output)

proc rleCompress(data: seq[uint8]): seq[uint8] =
  var buf = data
  separateHalves(buf)
  samplesToDifferences(buf)
  var output: seq[uint8] = @[]
  var runStart = 0
  var runEnd = 1
  let n = buf.len
  while runStart < n:
    while runEnd < n and buf[runStart] == buf[runEnd] and
        (runEnd - runStart) - 1 < 127:
      inc(runEnd)
    if runEnd - runStart >= 3:
      output.add(uint8(runEnd - runStart - 1))
      output.add(buf[runStart])
      runStart = runEnd
    else:
      while runEnd < n and (
          (runEnd + 1 >= n or buf[runEnd] != buf[runEnd+1]) or
          (runEnd + 2 >= n or buf[runEnd+1] != buf[runEnd+2])
        ) and runEnd - runStart < 127:
        inc(runEnd)
      output.add(uint8(256 - (runEnd - runStart))) # negative count
      for i in runStart..<runEnd: output.add(buf[i])
      runStart = runEnd
      inc(runEnd)
  output

# ---------- header parsing ----------

type ExrChannel = object
  name: string
  pixelType: int32 # 0=uint 1=half 2=float
  xSamp, ySamp: int32

proc rd32le(d: openArray[uint8], off: int): uint32 =
  uint32(d[off]) or (uint32(d[off+1]) shl 8) or (uint32(d[off+2]) shl 16) or
    (uint32(d[off+3]) shl 24)

proc rdI32le(d: openArray[uint8], off: int): int32 = cast[int32](rd32le(d, off))

proc readName(data: seq[uint8], pos: var int, maxLen: int): tuple[ok: bool, s: string] =
  var s = ""
  while pos < data.len and data[pos] != 0:
    s.add(char(data[pos])); inc(pos)
    if s.len > maxLen: return (false, "")
  if pos >= data.len: return (false, "")
  inc(pos) # skip NUL
  (true, s)

proc decodeExrAll*(data: seq[uint8]): ImageResult[seq[DynamicImage]] =
  if data.len < 8:
    return err[seq[DynamicImage]](decodingError("exr: too short"))
  for i in 0..3:
    if data[i] != ExrMagic[i]:
      return err[seq[DynamicImage]](decodingError("exr: bad magic"))
  let ver = rd32le(data, 4)
  if (ver and 0xFF) != 2:
    return err[seq[DynamicImage]](decodingError("exr: bad version"))
  if (ver and 0x200) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: tiled"))
  if (ver and 0x1000) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: multipart"))
  if (ver and 0x800) != 0:
    return err[seq[DynamicImage]](unsupportedError(ukGenericFeature, "exr: deep/non-image"))
  var pos = 8
  var channels: seq[ExrChannel] = @[]
  var compression = -1
  var dataWin = [0, 0, -1, -1]
  var dispWin = [0, 0, -1, -1]
  var lineOrder = 0
  while true:
    if pos >= data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated header"))
    if data[pos] == 0:
      inc(pos); break
    let (okN, name) = readName(data, pos, 255)
    if not okN:
      return err[seq[DynamicImage]](decodingError("exr: bad attr name"))
    let (okT, typ) = readName(data, pos, 31)
    if not okT:
      return err[seq[DynamicImage]](decodingError("exr: bad attr type"))
    if pos + 4 > data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated attr size"))
    let size = int(rd32le(data, pos)); pos += 4
    if pos + size > data.len:
      return err[seq[DynamicImage]](decodingError("exr: truncated attr"))
    let val = data[pos..<pos+size]; pos += size
    case name
    of "channels":
      var q = 0
      while q < val.len and val[q] != 0:
        # channel name (NUL-terminated)
        var e2 = q
        while e2 < val.len and val[e2] != 0: inc(e2)
        if e2 + 17 > val.len: break
        var nm = ""
        for k in q..<e2: nm.add(char(val[k]))
        let pt = rdI32le(val, e2 + 1)
        let xs = rdI32le(val, e2 + 9)
        let ys = rdI32le(val, e2 + 13)
        channels.add(ExrChannel(name: nm, pixelType: pt, xSamp: xs, ySamp: ys))
        q = e2 + 17
    of "compression":
      if val.len >= 1: compression = int(val[0])
    of "dataWindow":
      if val.len >= 16:
        for i in 0..3: dataWin[i] = cast[int32](rd32le(val, i*4))
    of "displayWindow":
      if val.len >= 16:
        for i in 0..3: dispWin[i] = cast[int32](rd32le(val, i*4))
    of "lineOrder":
      if val.len >= 1: lineOrder = int(val[0])
    else: discard
  if channels.len == 0 or compression < 0:
    return err[seq[DynamicImage]](decodingError("exr: missing header"))
  if dataWin[2] < dataWin[0] or dataWin[3] < dataWin[1]:
    return err[seq[DynamicImage]](decodingError("exr: bad data window"))
  let w = int(dataWin[2] - dataWin[0] + 1)
  let h = int(dataWin[3] - dataWin[1] + 1)
  if w <= 0 or h <= 0 or w > 1 shl 24 or h > 1 shl 24:
    return err[seq[DynamicImage]](limitError(lkDimensionError, "exr: dimensions"))
  for c in channels:
    if c.xSamp != 1 or c.ySamp != 1:
      return err[seq[DynamicImage]](unsupportedError(ukGenericFeature,
        "exr: subsampled channels"))
    if c.pixelType notin [0'i32, 1, 2]:
      return err[seq[DynamicImage]](unsupportedError(ukColor, "exr: sample type"))
  # rows per chunk + bytes per line
  var chanBytes: seq[int] = @[]
  for c in channels:
    chanBytes.add(if c.pixelType == 1: 2 else: 4)
  let lineBytes = block:
    var s = 0
    for i, c in channels: s += w * chanBytes[i]
    s
  let rowsPerChunk =
    case compression
    of 0, 1, 2: 1
    of 3: 16
    else:
      return err[seq[DynamicImage]](unsupportedError(ukGenericFeature,
        "exr: compression " & $compression))
  let nChunks = (h + rowsPerChunk - 1) div rowsPerChunk
  if pos + 8 * nChunks > data.len:
    return err[seq[DynamicImage]](decodingError("exr: truncated offset table"))
  var offsets = newSeq[uint64](nChunks)
  for i in 0..<nChunks:
    var o = 0'u64
    for b in 0..7: o = o or (uint64(data[pos+i*8+b]) shl (8*b))
    offsets[i] = o
  pos += 8 * nChunks
  # gather (y, bytes) per chunk
  type Chunk = tuple[y: int, raw: seq[uint8]]
  var chunks: seq[Chunk] = @[]
  for i in 0..<nChunks:
    let o = int(offsets[i])
    if o + 8 > data.len:
      return err[seq[DynamicImage]](decodingError("exr: chunk OOB"))
    let y = int(cast[int32](rd32le(data, o)))
    let sz = int(rd32le(data, o + 4))
    if o + 8 + sz > data.len:
      return err[seq[DynamicImage]](decodingError("exr: chunk data OOB"))
    chunks.add((y, data[o+8..<o+8+sz]))
  # sort by y; row mapping per lineOrder
  var order = newSeq[int](chunks.len)
  for i in 0..<order.len: order[i] = i
  # insertion sort by y (chunk counts are small; avoid algorithm import)
  for i in 1..<order.len:
    let t = order[i]
    var j = i - 1
    while j >= 0 and chunks[order[j]].y > chunks[t].y:
      order[j+1] = order[j]; dec(j)
    order[j+1] = t
  var full = newSeq[uint8](h * lineBytes)
  for oi in order:
    let (yAbs, comp) = chunks[oi]
    var firstRow =
      if lineOrder == 1: dataWin[3] - yAbs
      else: yAbs - dataWin[1]
    let rows = min(rowsPerChunk, h - firstRow)
    if firstRow < 0 or rows <= 0: continue
    let exp = rows * lineBytes
    var blk: seq[uint8]
    case compression
    of 0:
      if comp.len < exp:
        return err[seq[DynamicImage]](decodingError("exr: short raw chunk"))
      blk = comp[0..<exp]
    of 1:
      let r = rleDecompress(comp, exp)
      if not r.ok: return err[seq[DynamicImage]](r.err)
      blk = r.value
    of 2, 3:
      let r = inflateZlib(comp, exp)
      if not r.ok: return err[seq[DynamicImage]](r.err)
      if r.value.len < exp:
        return err[seq[DynamicImage]](decodingError("exr: short zip chunk"))
      blk = r.value[0..<exp]
      differencesToSamples(blk)
      interleaveHalves(blk)
    else: discard
    for r in 0..<rows:
      for i in 0..<lineBytes:
        full[(firstRow+r)*lineBytes+i] = blk[r*lineBytes+i]
  # samples -> DynamicImage (all to f32). Chunk data is chunky-interleaved.
  var coff = newSeq[int](channels.len)
  var stride = 0
  for ci in 0..<channels.len:
    coff[ci] = stride
    stride += chanBytes[ci]
  proc getF(lineOff, x, ci: int): float32 =
    let o = lineOff + x * stride + coff[ci]
    case channels[ci].pixelType
    of 0:
      let u = uint32(full[o]) or (uint32(full[o+1]) shl 8) or
        (uint32(full[o+2]) shl 16) or (uint32(full[o+3]) shl 24)
      float32(u)
    of 1:
      halfToFloat(uint16(full[o]) or (uint16(full[o+1]) shl 8))
    else:
      let u = uint32(full[o]) or (uint32(full[o+1]) shl 8) or
        (uint32(full[o+2]) shl 16) or (uint32(full[o+3]) shl 24)
      cast[float32](u)
  let names = channels.mapIt(it.name)
  proc findCh(nm: string): int =
    for i, n in names:
      if n == nm: return i
    -1
  let ri = findCh("R"); let gi = findCh("G"); let bi = findCh("B")
  let ai = findCh("A"); let yi = findCh("Y")
  if ri >= 0 and gi >= 0 and bi >= 0 and yi < 0:
    var px = newSeq[Rgb[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w:
        px[y*w+x] = Rgb[float32](data: [getF(lo, x, ri), getF(lo, x, gi),
          getF(lo, x, bi)])
    if ai >= 0:
      var pxa = newSeq[Rgba[float32]](w*h)
      for y in 0..<h:
        let lo = y * lineBytes
        for x in 0..<w:
          pxa[y*w+x] = Rgba[float32](data: [getF(lo, x, ri), getF(lo, x, gi),
            getF(lo, x, bi), getF(lo, x, ai)])
      return ok(@[DynamicImage(kind: dkRgba32F, rgba32f:
        Rgba32FImage(width: uint32(w), height: uint32(h), pixels: pxa))])
    return ok(@[DynamicImage(kind: dkRgb32F, rgb32f:
      Rgb32FImage(width: uint32(w), height: uint32(h), pixels: px))])
  elif yi >= 0:
    if ai >= 0:
      var px = newSeq[LumaA[float32]](w*h)
      for y in 0..<h:
        let lo = y * lineBytes
        for x in 0..<w:
          px[y*w+x] = LumaA[float32](data: [getF(lo, x, yi), getF(lo, x, ai)])
      return ok(@[DynamicImage(kind: dkLumaA32F, lumaA32f:
        GrayAlpha32FImage(width: uint32(w), height: uint32(h), pixels: px))])
    var px = newSeq[Luma[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w: px[y*w+x] = Luma[float32](data: [getF(lo, x, yi)])
    return ok(@[DynamicImage(kind: dkLuma32F, luma32f:
      Gray32FImage(width: uint32(w), height: uint32(h), pixels: px))])
  elif ai >= 0 and ri < 0:
    # Alpha-only treated as luma (documented; matches TGA/BMP precedent).
    var pl = newSeq[Luma[float32]](w*h)
    for y in 0..<h:
      let lo = y * lineBytes
      for x in 0..<w: pl[y*w+x] = Luma[float32](data: [getF(lo, x, ai)])
    return ok(@[DynamicImage(kind: dkLuma32F, luma32f:
      Gray32FImage(width: uint32(w), height: uint32(h), pixels: pl))])
  return err[seq[DynamicImage]](unsupportedError(ukColor,
    "exr: channel set " & $names))

proc decodeExr*(data: seq[uint8]): ImageResult[DynamicImage] =
  let r = decodeExrAll(data)
  if not r.ok: return err[DynamicImage](r.err)
  ok(r.value[0])

proc putU32le(dst: var seq[uint8], v: uint32) =
  dst.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF),
    uint8((v shr 16) and 0xFF), uint8((v shr 24) and 0xFF)])

proc putAttr(dst: var seq[uint8], name, typ: string, val: seq[uint8]) =
  for c in name: dst.add(uint8(c))
  dst.add(0)
  for c in typ: dst.add(uint8(c))
  dst.add(0)
  putU32le(dst, uint32(val.len))
  for b in val: dst.add(b)

proc putBox(dst: var seq[uint8], x0, y0, x1, y1: int32) =
  for v in [x0, y0, x1, y1]:
    putU32le(dst, cast[uint32](v))

proc encodeExr*(img: DynamicImage): ImageResult[seq[uint8]] =
  ## ZIP scanline writer. Accepts Rgb32F/Rgba32F/Luma32F (convert first).
  var w, h: int
  var chNames: seq[string] = @[]
  var raw: seq[uint8] = @[]
  case img.kind
  of dkRgb32F:
    w = int(img.rgb32f.width); h = int(img.rgb32f.height)
    chNames = @["R", "G", "B"]
    raw = newSeq[uint8](w*h*12)
    for i, p in img.rgb32f.pixels:
      for c in 0..2:
        let u = cast[uint32](p.data[c])
        raw[12*i+4*c]=uint8(u and 0xFF); raw[12*i+4*c+1]=uint8((u shr 8) and 0xFF)
        raw[12*i+4*c+2]=uint8((u shr 16) and 0xFF); raw[12*i+4*c+3]=uint8((u shr 24) and 0xFF)
  of dkRgba32F:
    w = int(img.rgba32f.width); h = int(img.rgba32f.height)
    chNames = @["R", "G", "B", "A"]
    raw = newSeq[uint8](w*h*16)
    for i, p in img.rgba32f.pixels:
      for c in 0..3:
        let u = cast[uint32](p.data[c])
        raw[16*i+4*c]=uint8(u and 0xFF); raw[16*i+4*c+1]=uint8((u shr 8) and 0xFF)
        raw[16*i+4*c+2]=uint8((u shr 16) and 0xFF); raw[16*i+4*c+3]=uint8((u shr 24) and 0xFF)
  of dkLuma32F:
    w = int(img.luma32f.width); h = int(img.luma32f.height)
    chNames = @["Y"]
    raw = newSeq[uint8](w*h*4)
    for i, p in img.luma32f.pixels:
      let u = cast[uint32](p.data[0])
      raw[4*i]=uint8(u and 0xFF); raw[4*i+1]=uint8((u shr 8) and 0xFF)
      raw[4*i+2]=uint8((u shr 16) and 0xFF); raw[4*i+3]=uint8((u shr 24) and 0xFF)
  else:
    return err[seq[uint8]](unsupportedError(ukColor, "exr: encode this variant first"))
  if w == 0 or h == 0:
    return err[seq[uint8]](paramError(pkDimensionMismatch, "exr: empty"))
  var output = @ExrMagic
  putU32le(output, 2)
  # chlist
  var chl: seq[uint8] = @[]
  for n in chNames:
    for c in n: chl.add(uint8(c))
    chl.add(0)
    putU32le(chl, 2) # float
    chl.add(0) # pLinear
    chl.add([0'u8, 0, 0]) # reserved
    putU32le(chl, 1); putU32le(chl, 1) # sampling
  chl.add(0) # terminator
  putAttr(output, "channels", "chlist", chl)
  putAttr(output, "compression", "compression", @[3'u8]) # ZIP
  var bw: seq[uint8] = @[]
  putBox(bw, 0, 0, int32(w-1), int32(h-1))
  putAttr(output, "dataWindow", "box2i", bw)
  putAttr(output, "displayWindow", "box2i", bw)
  putAttr(output, "lineOrder", "lineOrder", @[0'u8])
  var par: seq[uint8] = @[]
  let pa = cast[uint32](1.0'f32)
  par.add([uint8(pa and 0xFF), uint8((pa shr 8) and 0xFF),
    uint8((pa shr 16) and 0xFF), uint8((pa shr 24) and 0xFF)])
  putAttr(output, "pixelAspectRatio", "float", par)
  putAttr(output, "screenWindowCenter", "v2f", @[0'u8,0,0,0, 0,0,0,0])
  putAttr(output, "screenWindowWidth", "float", @[0'u8,0,0,0])
  output.add(0) # end of header
  # chunks: ZIP = 16 rows each
  let rowsPer = 16
  let lineBytes = w * chNames.len * 4
  let nChunks = (h + rowsPer - 1) div rowsPer
  # offset table placeholder
  let tabOff = output.len
  for _ in 0..<nChunks:
    for _ in 0..7: output.add(0)
  var chunkData: seq[seq[uint8]] = @[]
  for ci in 0..<nChunks:
    let y0 = ci * rowsPer
    let rows = min(rowsPer, h - y0)
    var blk = raw[y0*lineBytes..<y0*lineBytes+rows*lineBytes]
    separateHalves(blk)
    samplesToDifferences(blk)
    let cr = deflateZlib(blk, 6)
    if not cr.ok: return err[seq[uint8]](cr.err)
    var ch: seq[uint8] = @[]
    putU32le(ch, uint32(y0))
    putU32le(ch, uint32(cr.value.len))
    for b in cr.value: ch.add(b)
    chunkData.add(ch)
  var doff = output.len
  for i, ch in chunkData:
    for b in 0..7:
      output[tabOff+i*8+b] = uint8((uint64(doff) shr (8*b)) and 0xFF)
    for b in ch: output.add(b)
    doff += ch.len
  ok(output)
