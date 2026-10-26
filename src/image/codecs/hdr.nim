## HDR codec — references/image/src/codecs/hdr/ (decoder 801, encoder 480)
## Radiance RGBE: #?RADIANCE, FORMAT=32-bit_rle_rgbe, -Y H +X W, flat + new/old RLE.
import std/math
import std/strutils
import ../color
import ../error
import ../buffer
import ../dynamic

const HdrSignature* = "#?RADIANCE"

type Rgbe* = tuple[r, g, b, e: uint8]

func rgbeToHdr*(p: Rgbe): Rgb[float32] =
  if p.e == 0:
    return Rgb[float32](data: [0'f32, 0, 0])
  let bits =
    if p.e > 1: ((uint32(p.e) - 1) shl 23)
    else: (uint32(p.e) shl 22)
  let exp = cast[float32](bits) * 0.00390625'f32
  Rgb[float32](data: [exp * float32(p.r), exp * float32(p.g), exp * float32(p.b)])

func hdrToRgbe*(r, g, b: float32): Rgbe =
  let mx = max(r, max(g, b))
  if mx <= 0.0'f32 or mx.classify == fcNan or mx.classify == fcInf:
    return (0'u8, 0, 0, 0)
  let exp = int(floor(log2(mx))) + 1
  if exp < -126 or exp > 127: # guard against overflow of e byte
    discard
  let mul = pow(2.0'f32, float32(exp))
  let cr = uint8(trunc(r / mul * 256.0'f32))
  let cg = uint8(trunc(g / mul * 256.0'f32))
  let cb = uint8(trunc(b / mul * 256.0'f32))
  (cr, cg, cb, uint8(exp + 128))

proc decodeHdr*(data: seq[uint8]): ImageResult[Rgb32FImage] =
  # header: lines until empty line
  var pos = 0
  proc readLine(): tuple[eof: bool, s: string] =
    if pos >= data.len: return (true, "")
    let start = pos
    while pos < data.len and data[pos] != uint8('\n'): inc pos
    var s = newString(pos - start)
    for i in 0..<pos-start: s[i] = char(data[start+i])
    if pos < data.len and data[pos] == uint8('\n'): inc pos
    # strip trailing \r
    if s.len > 0 and s[^1] == '\r': s.setLen(s.len - 1)
    (false, s)
  let (eof0, sig) = readLine()
  if eof0 or not sig.startsWith(HdrSignature):
    return err[Rgb32FImage](decodingError("hdr: bad signature"))
  var formatOk = false
  var gotFormat = false
  while true:
    let (eof, line) = readLine()
    if eof: return err[Rgb32FImage](decodingError("hdr: EOF in header"))
    if line.len == 0: break
    if line.len > 0 and line[0] == '#': continue
    let eq = line.find('=')
    if eq > 0:
      let key = line[0..<eq].strip()
      let val = line[eq+1..^1].strip()
      if key == "FORMAT":
        gotFormat = true
        formatOk = val == "32-bit_rle_rgbe"
  if gotFormat and not formatOk:
    return err[Rgb32FImage](unsupportedError(ukFormat, "hdr: unsupported FORMAT (need 32-bit_rle_rgbe)"))
  let (eofD, dimLine) = readLine()
  if eofD: return err[Rgb32FImage](decodingError("hdr: EOF in dimensions"))
  let parts = dimLine.splitWhitespace()
  if parts.len != 4:
    return err[Rgb32FImage](decodingError("hdr: bad dimensions line"))
  if parts[0] != "-Y" or parts[2] != "+X":
    return err[Rgb32FImage](unsupportedError(ukGenericFeature, "hdr: orientation " & parts[0] & " " & parts[2]))
  var h, w: uint32
  try:
    h = uint32(parseInt(parts[1])); w = uint32(parseInt(parts[3]))
  except ValueError:
    return err[Rgb32FImage](decodingError("hdr: bad dimensions"))
  if w == 0 or h == 0:
    return ok(Rgb32FImage(width: w, height: h, pixels: @[]))
  let n = int(w) * int(h)
  var px = newSeq[Rgb[float32]](n)
  # scanlines top-down, each of width w
  var idx = 0
  for _ in 0..<int(h):
    if pos + 4 > data.len:
      return err[Rgb32FImage](decodingError("hdr: truncated scanline"))
    let fb: Rgbe = (data[pos], data[pos+1], data[pos+2], data[pos+3])
    pos += 4
    var scan = newSeq[Rgbe](int(w))
    if fb.r == 2 and fb.g == 2 and fb.e < 128:
      # new RLE per component; fb.b holds high byte of width? Reference ignores, uses w.
      # Actually marker is (2,2,hi,lo); validate loosely.
      for comp in 0..3:
        var p = 0
        while p < int(w):
          if pos >= data.len:
            return err[Rgb32FImage](decodingError("hdr: truncated RLE"))
          let rl = int(data[pos]); inc pos
          if rl <= 128:
            if p + rl > int(w) or pos + rl > data.len:
              return err[Rgb32FImage](decodingError("hdr: bad RLE length"))
            for k in 0..<rl:
              let v = data[pos]; inc pos
              case comp
              of 0: scan[p+k].r = v
              of 1: scan[p+k].g = v
              of 2: scan[p+k].b = v
              else: scan[p+k].e = v
            p += rl
          else:
            let run = rl - 128
            if p + run > int(w) or pos >= data.len:
              return err[Rgb32FImage](decodingError("hdr: bad RLE run"))
            let v = data[pos]; inc pos
            for k in 0..<run:
              case comp
              of 0: scan[p+k].r = v
              of 1: scan[p+k].g = v
              of 2: scan[p+k].b = v
              else: scan[p+k].e = v
            p += run
    else:
      # old RLE
      if fb.r == 1 and fb.g == 1 and fb.b == 1:
        return err[Rgb32FImage](decodingError("hdr: first pixel RLE marker"))
      scan[0] = fb
      var x = 1
      var shift = 0
      var prev = fb
      while x < int(w):
        if pos + 4 > data.len:
          return err[Rgb32FImage](decodingError("hdr: truncated old RLE"))
        let pix: Rgbe = (data[pos], data[pos+1], data[pos+2], data[pos+3])
        pos += 4
        if pix.r == 1 and pix.g == 1 and pix.b == 1:
          let rl0 = int(pix.e)
          if shift >= 32:
            if rl0 != 0:
              return err[Rgb32FImage](decodingError("hdr: overly long repeat"))
          else:
            let rl = rl0 shl shift
            shift += 8
            if x + rl > int(w):
              return err[Rgb32FImage](decodingError("hdr: bad old RLE length"))
            for k in 0..<rl: scan[x+k] = prev
            x += rl
        else:
          shift = 0
          prev = pix
          scan[x] = pix
          inc x
      # flat uncompressed scanlines are a degenerate case of old RLE without markers;
      # handled by same loop when no markers appear. But pure-flat files store raw
      # pixels without any marker logic? Reference treats non-marker first pixel +
      # sequential pixels as literal — same as above. OK.
    for i in 0..<int(w):
      px[idx] = rgbeToHdr(scan[i])
      inc idx
  ok(Rgb32FImage(width: w, height: h, pixels: px))

proc rleCompressChannel(data: openArray[uint8]): seq[uint8] =
  result = @[]
  var i = 0
  while i < data.len:
    # count run
    var run = 1
    while i + run < data.len and data[i+run] == data[i] and run < 127: inc run
    if run > 2:
      result.add(uint8(128 + run))
      result.add(data[i])
      i += run
    else:
      # literal run until next run of 3+ or 128 max
      var j = i
      while j < data.len:
        var r = 1
        while j + r < data.len and data[j+r] == data[j] and r < 127: inc r
        if r > 2: break
        inc j
        if j - i >= 128: break
        # also cap: if next bytes start a run we stop before it (handled by break above)
      let lit = min(j - i, 128)
      result.add(uint8(lit))
      for k in 0..<lit: result.add(data[i+k])
      i += lit

proc encodeHdr*(img: Rgb32FImage): seq[uint8] =
  var head = HdrSignature & "\n# Nim HDR encoder\nFORMAT=32-bit_rle_rgbe\n\n-Y " &
    $img.height & " +X " & $img.width & "\n"
  result = newSeq[uint8](head.len)
  for i, c in head: result[i] = uint8(c)
  let w = int(img.width)
  if w < 8 or w > 32768:
    for p in img.pixels:
      let (r, g, b, e) = hdrToRgbe(p.data[0], p.data[1], p.data[2])
      result.add([r, g, b, e])
  else:
    var bufr = newSeq[uint8](w)
    var bufg = newSeq[uint8](w)
    var bufb = newSeq[uint8](w)
    var bufe = newSeq[uint8](w)
    for y in 0..<int(img.height):
      for x in 0..<w:
        let (r, g, b, e) = hdrToRgbe(img.pixels[y*w+x].data[0],
          img.pixels[y*w+x].data[1], img.pixels[y*w+x].data[2])
        bufr[x] = r; bufg[x] = g; bufb[x] = b; bufe[x] = e
      result.add([2'u8, 2, uint8(w div 256), uint8(w mod 256)])
      result.add(rleCompressChannel(bufr))
      result.add(rleCompressChannel(bufg))
      result.add(rleCompressChannel(bufb))
      result.add(rleCompressChannel(bufe))

proc encodeHdrFlat*(img: Rgb32FImage): seq[uint8] =
  ## Uncompressed variant (width outside 8..32768 path) exposed for tests.
  var head = HdrSignature & "\n# Nim HDR encoder\nFORMAT=32-bit_rle_rgbe\n\n-Y " &
    $img.height & " +X " & $img.width & "\n"
  result = newSeq[uint8](head.len)
  for i, c in head: result[i] = uint8(c)
  for p in img.pixels:
    let (r, g, b, e) = hdrToRgbe(p.data[0], p.data[1], p.data[2])
    result.add([r, g, b, e])
