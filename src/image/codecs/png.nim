## PNG codec — references/image/src/codecs/png.rs (1183) + png@0.18.0
## Signature, IHDR, PLTE/tRNS, IDAT inflate (pkg/zlib), 5 filters, Adam7,
## color types 0/2/3/4/6, depths 1/2/4/8/16. APNG IDAT still decoded.
import ../color
import ../error
import ../buffer
import ../dynamic
import ../zlibwrap
import ../simd

const PngSig* = [137'u8, 80, 78, 71, 13, 10, 26, 10]

const
  Adam7X* = [0, 4, 0, 2, 0, 1, 0]
  Adam7Y* = [0, 0, 4, 0, 2, 0, 1]
  Adam7DX* = [8, 8, 4, 4, 2, 2, 1]
  Adam7DY* = [8, 8, 8, 4, 4, 2, 2]

proc u32be(d: openArray[uint8], off: int): uint32 =
  (uint32(d[off]) shl 24) or (uint32(d[off+1]) shl 16) or
    (uint32(d[off+2]) shl 8) or uint32(d[off+3])

proc chunkCrc*(typ: array[4, uint8], data: openArray[uint8]): uint32 =
  var buf = newSeq[uint8](4 + data.len)
  for i in 0..3: buf[i] = typ[i]
  for i, b in data: buf[4+i] = b
  crc32raw(buf)

proc bitVal(row: openArray[uint8], bitpos: int): int =
  int((row[bitpos div 8] shr uint8(7 - (bitpos mod 8))) and 1)

proc buildFromSamples(colorType, bitDepth: uint8, w, h: int,
    get: proc(x, y, c: int): uint16,
    plte: seq[tuple[r, g, b: uint8]], trnsAlpha: seq[uint8],
    trnsGray: int, trnsRgb: tuple[r, g, b: int]): ImageResult[DynamicImage] =
  ## get(x,y,c) returns the sample value (8- or 16-bit per bitDepth).
  if colorType == 3:
    if trnsAlpha.len > 0:
      var px = newSeq[Rgba[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          let v = int(get(x, y, 0))
          if v >= plte.len:
            return err[DynamicImage](decodingError("png: palette index OOB"))
          let c = plte[v]
          px[y*w+x] = Rgba[uint8](data: [c.r, c.g, c.b,
            if v < trnsAlpha.len: trnsAlpha[v] else: 255'u8])
      return ok(DynamicImage(kind: dkRgba8,
        rgba8: RgbaImage(width: uint32(w), height: uint32(h), pixels: px)))
    else:
      var px = newSeq[Rgb[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          let v = int(get(x, y, 0))
          if v >= plte.len:
            return err[DynamicImage](decodingError("png: palette index OOB"))
          let c = plte[v]
          px[y*w+x] = Rgb[uint8](data: [c.r, c.g, c.b])
      return ok(DynamicImage(kind: dkRgb8,
        rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: px)))
  elif colorType == 0:
    if bitDepth == 16:
      var px = newSeq[Luma[uint16]](w * h)
      for y in 0..<h:
        for x in 0..<w: px[y*w+x] = Luma[uint16](data: [get(x, y, 0)])
      if trnsGray >= 0:
        var pxa = newSeq[LumaA[uint16]](w * h)
        for i, p in px:
          pxa[i] = LumaA[uint16](data: [p.data[0],
            if int(p.data[0]) == trnsGray: 0'u16 else: 65535'u16])
        return ok(DynamicImage(kind: dkLumaA16, lumaA16:
          GrayAlpha16Image(width: uint32(w), height: uint32(h), pixels: pxa)))
      return ok(DynamicImage(kind: dkLuma16,
        luma16: Gray16Image(width: uint32(w), height: uint32(h), pixels: px)))
    else:
      let maxv = (1 shl int(bitDepth)) - 1
      var px = newSeq[Luma[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          let v = int(get(x, y, 0))
          px[y*w+x] = Luma[uint8](data: [uint8((v * 255 + maxv div 2) div maxv)])
      if trnsGray >= 0:
        var pxa = newSeq[LumaA[uint8]](w * h)
        for y in 0..<h:
          for x in 0..<w:
            let v = int(get(x, y, 0))
            pxa[y*w+x] = LumaA[uint8](data: [px[y*w+x].data[0],
              if (v * 65535) div maxv == trnsGray: 0'u8 else: 255'u8])
        return ok(DynamicImage(kind: dkLumaA8, lumaA8:
          GrayAlphaImage(width: uint32(w), height: uint32(h), pixels: pxa)))
      return ok(DynamicImage(kind: dkLuma8,
        luma8: GrayImage(width: uint32(w), height: uint32(h), pixels: px)))
  elif colorType == 2:
    if bitDepth == 16:
      var px = newSeq[Rgb[uint16]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = Rgb[uint16](data: [get(x, y, 0), get(x, y, 1), get(x, y, 2)])
      if trnsRgb.r >= 0:
        var pxa = newSeq[Rgba[uint16]](w * h)
        for i, p in px:
          let a = if int(p.data[0]) == trnsRgb.r and int(p.data[1]) == trnsRgb.g and
              int(p.data[2]) == trnsRgb.b: 0'u16 else: 65535'u16
          pxa[i] = Rgba[uint16](data: [p.data[0], p.data[1], p.data[2], a])
        return ok(DynamicImage(kind: dkRgba16, rgba16:
          Rgba16Image(width: uint32(w), height: uint32(h), pixels: pxa)))
      return ok(DynamicImage(kind: dkRgb16,
        rgb16: Rgb16Image(width: uint32(w), height: uint32(h), pixels: px)))
    else:
      var px = newSeq[Rgb[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = Rgb[uint8](data: [uint8(get(x, y, 0)), uint8(get(x, y, 1)),
            uint8(get(x, y, 2))])
      if trnsRgb.r >= 0:
        var pxa = newSeq[Rgba[uint8]](w * h)
        for i, p in px:
          let a = if int(p.data[0]) == trnsRgb.r and int(p.data[1]) == trnsRgb.g and
              int(p.data[2]) == trnsRgb.b: 0'u8 else: 255'u8
          pxa[i] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2], a])
        return ok(DynamicImage(kind: dkRgba8, rgba8:
          RgbaImage(width: uint32(w), height: uint32(h), pixels: pxa)))
      return ok(DynamicImage(kind: dkRgb8,
        rgb8: RgbImage(width: uint32(w), height: uint32(h), pixels: px)))
  elif colorType == 4:
    if bitDepth == 16:
      var px = newSeq[LumaA[uint16]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = LumaA[uint16](data: [get(x, y, 0), get(x, y, 1)])
      return ok(DynamicImage(kind: dkLumaA16, lumaA16:
        GrayAlpha16Image(width: uint32(w), height: uint32(h), pixels: px)))
    else:
      var px = newSeq[LumaA[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = LumaA[uint8](data: [uint8(get(x, y, 0)), uint8(get(x, y, 1))])
      return ok(DynamicImage(kind: dkLumaA8, lumaA8:
        GrayAlphaImage(width: uint32(w), height: uint32(h), pixels: px)))
  else: # colorType 6
    if bitDepth == 16:
      var px = newSeq[Rgba[uint16]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = Rgba[uint16](data: [get(x, y, 0), get(x, y, 1),
            get(x, y, 2), get(x, y, 3)])
      return ok(DynamicImage(kind: dkRgba16, rgba16:
        Rgba16Image(width: uint32(w), height: uint32(h), pixels: px)))
    else:
      var px = newSeq[Rgba[uint8]](w * h)
      for y in 0..<h:
        for x in 0..<w:
          px[y*w+x] = Rgba[uint8](data: [uint8(get(x, y, 0)), uint8(get(x, y, 1)),
            uint8(get(x, y, 2)), uint8(get(x, y, 3))])
      return ok(DynamicImage(kind: dkRgba8, rgba8:
        RgbaImage(width: uint32(w), height: uint32(h), pixels: px)))

proc decodePng*(data: seq[uint8]): ImageResult[DynamicImage] =
  if data.len < 8:
    return err[DynamicImage](decodingError("png: too short"))
  for i in 0..7:
    if data[i] != PngSig[i]:
      return err[DynamicImage](decodingError("png: bad signature"))
  var pos = 8
  var width = 0'u32; var height = 0'u32
  var bitDepth = 0'u8; var colorType = 0'u8
  var interlace = 0'u8
  var gotIhdr = false
  var plte: seq[tuple[r, g, b: uint8]] = @[]
  var trnsAlpha: seq[uint8] = @[]
  var trnsGray = -1; var trnsRgb = (-1, -1, -1)
  var idat: seq[uint8] = @[]
  var sawIend = false
  while pos + 8 <= data.len:
    let length = int(u32be(data, pos))
    let typ = [data[pos+4], data[pos+5], data[pos+6], data[pos+7]]
    if pos + 12 + length > data.len:
      return err[DynamicImage](decodingError("png: truncated chunk"))
    let body = data[pos+8..<pos+8+length]
    if chunkCrc(typ, body) != u32be(data, pos + 8 + length):
      return err[DynamicImage](decodingError("png: CRC mismatch"))
    pos += 12 + length
    let ts = "" & char(typ[0]) & char(typ[1]) & char(typ[2]) & char(typ[3])
    if ts == "IHDR":
      if gotIhdr or length != 13:
        return err[DynamicImage](decodingError("png: bad IHDR"))
      gotIhdr = true
      width = u32be(body, 0); height = u32be(body, 4)
      bitDepth = body[8]; colorType = body[9]
      if body[10] != 0 or body[11] != 0:
        return err[DynamicImage](decodingError("png: bad compression/filter"))
      interlace = body[12]
      if interlace > 1:
        return err[DynamicImage](decodingError("png: bad interlace"))
      if width == 0 or height == 0:
        return err[DynamicImage](decodingError("png: empty image"))
      if colorType notin [0'u8, 2, 3, 4, 6]:
        return err[DynamicImage](unsupportedError(ukColor, "png: color type " & $colorType))
      if colorType == 3 and bitDepth notin [1'u8, 2, 4, 8]:
        return err[DynamicImage](decodingError("png: bad palette depth"))
      elif colorType in [0'u8, 4] and bitDepth notin [1'u8, 2, 4, 8, 16]:
        return err[DynamicImage](decodingError("png: bad gray depth"))
      elif colorType in [2'u8, 6] and bitDepth notin [8'u8, 16]:
        return err[DynamicImage](decodingError("png: bad truecolor depth"))
    elif ts == "PLTE":
      var i = 0
      while i + 2 < body.len:
        plte.add((body[i], body[i+1], body[i+2])); i += 3
    elif ts == "tRNS":
      if colorType == 3:
        trnsAlpha = body
      elif colorType == 0 and body.len >= 2:
        trnsGray = int((uint16(body[0]) shl 8) or uint16(body[1]))
      elif colorType == 2 and body.len >= 6:
        trnsRgb = (int((uint16(body[0]) shl 8) or uint16(body[1])),
          int((uint16(body[2]) shl 8) or uint16(body[3])),
          int((uint16(body[4]) shl 8) or uint16(body[5])))
    elif ts == "IDAT":
      for b in body: idat.add(b)
    elif ts == "IEND":
      sawIend = true
      break
    else:
      discard # skip ancillary (incl. APNG acTL/fcTL/fdAT)
  if not gotIhdr or not sawIend:
    return err[DynamicImage](decodingError("png: missing IHDR/IEND"))
  if colorType == 3 and plte.len == 0:
    return err[DynamicImage](decodingError("png: missing PLTE"))
  let channels =
    case colorType
    of 0: 1
    of 2: 3
    of 3: 1
    of 4: 2
    of 6: 4
    else: 0
  let w = int(width); let h = int(height)
  let r = inflateZlibGrow(idat)
  if not r.ok: return err[DynamicImage](r.err)
  var inflated = r.value
  var p = 0
  let sampBytes = if bitDepth == 16: 2 else: 1
  var fbpp = (channels * int(bitDepth)) div 8
  if fbpp == 0: fbpp = 1
  if interlace == 0:
    let rowBytes = (w * channels * int(bitDepth) + 7) div 8
    var prev = newSeq[uint8](rowBytes)
    var rawRows = newSeq[uint8](h * rowBytes)
    for y in 0..<h:
      if p + 1 + rowBytes > inflated.len:
        return err[DynamicImage](decodingError("png: truncated IDAT"))
      let f = inflated[p]; inc(p)
      var cur = inflated[p..<p+rowBytes]; p += rowBytes
      if not simdUnfilterRow(f, cur, prev, fbpp):
        return err[DynamicImage](decodingError("png: bad filter"))
      for i in 0..<rowBytes: rawRows[y*rowBytes+i] = cur[i]
      prev = cur
    if bitDepth >= 8:
      let bpc = channels * sampBytes
      proc get(x, y, c: int): uint16 =
        if sampBytes == 2:
          let o = y*rowBytes + x*bpc + c*2
          (uint16(rawRows[o]) shl 8) or uint16(rawRows[o+1])
        else:
          uint16(rawRows[y*rowBytes + x*bpc + c])
      return buildFromSamples(colorType, bitDepth, w, h, get, plte,
        trnsAlpha, trnsGray, trnsRgb)
    else:
      proc get(x, y, c: int): uint16 =
        let bitpos = (x * channels + c) * int(bitDepth)
        var v = 0
        for k in 0..<int(bitDepth):
          v = (v shl 1) or bitVal(rawRows.toOpenArray(y*rowBytes, y*rowBytes+rowBytes-1), bitpos + k)
        uint16(v)
      return buildFromSamples(colorType, bitDepth, w, h, get, plte,
        trnsAlpha, trnsGray, trnsRgb)
  else:
    # Adam7
    var full = newSeq[uint8](h * w * channels * sampBytes)
    for pass in 0..6:
      let pw = (w - Adam7X[pass] + Adam7DX[pass] - 1) div Adam7DX[pass]
      let ph = (h - Adam7Y[pass] + Adam7DY[pass] - 1) div Adam7DY[pass]
      if pw == 0 or ph == 0: continue
      let rowBytes = (pw * channels * int(bitDepth) + 7) div 8
      var prev = newSeq[uint8](rowBytes)
      var passRows = newSeq[uint8](ph * rowBytes)
      for y in 0..<ph:
        if p + 1 + rowBytes > inflated.len:
          return err[DynamicImage](decodingError("png: truncated Adam7"))
        let f = inflated[p]; inc(p)
        var cur = inflated[p..<p+rowBytes]; p += rowBytes
        if not simdUnfilterRow(f, cur, prev, fbpp):
          return err[DynamicImage](decodingError("png: bad filter"))
        for i in 0..<rowBytes: passRows[y*rowBytes+i] = cur[i]
        prev = cur
      if bitDepth >= 8:
        let bpc = channels * sampBytes
        for y in 0..<ph:
          for x in 0..<pw:
            let dx = Adam7X[pass] + x * Adam7DX[pass]
            let dy = Adam7Y[pass] + y * Adam7DY[pass]
            for k in 0..<bpc:
              full[(dy*w+dx)*bpc+k] = passRows[y*rowBytes + x*bpc + k]
      else:
        let maxv = (1 shl int(bitDepth)) - 1
        for y in 0..<ph:
          for x in 0..<pw:
            let dx = Adam7X[pass] + x * Adam7DX[pass]
            let dy = Adam7Y[pass] + y * Adam7DY[pass]
            for c in 0..<channels:
              var v = 0
              for k in 0..<int(bitDepth):
                v = (v shl 1) or bitVal(passRows.toOpenArray(
                  y*rowBytes, y*rowBytes+rowBytes-1),
                  (x*channels+c)*int(bitDepth)+k)
              full[(dy*w+dx)*channels+c] = uint8((v * 255 + maxv div 2) div maxv)
    if bitDepth >= 8:
      let bpc = channels * sampBytes
      proc get(x, y, c: int): uint16 =
        if sampBytes == 2:
          let o = (y*w+x)*bpc + c*2
          (uint16(full[o]) shl 8) or uint16(full[o+1])
        else:
          uint16(full[(y*w+x)*bpc+c])
      return buildFromSamples(colorType, bitDepth, w, h, get, plte,
        trnsAlpha, trnsGray, trnsRgb)
    else:
      proc get(x, y, c: int): uint16 =
        uint16(full[(y*w+x)*channels+c])
      return buildFromSamples(colorType, bitDepth, w, h, get, plte,
        trnsAlpha, trnsGray, trnsRgb)

proc encodeChunk(typ: array[4, uint8], body: openArray[uint8]): seq[uint8] =
  result = newSeq[uint8](8 + body.len + 4)
  let n = uint32(body.len)
  result[0] = uint8((n shr 24) and 0xFF); result[1] = uint8((n shr 16) and 0xFF)
  result[2] = uint8((n shr 8) and 0xFF); result[3] = uint8(n and 0xFF)
  for i in 0..3: result[4+i] = typ[i]
  for i, b in body: result[8+i] = b
  let c = chunkCrc(typ, body)
  result[8+body.len] = uint8((c shr 24) and 0xFF)
  result[8+body.len+1] = uint8((c shr 16) and 0xFF)
  result[8+body.len+2] = uint8((c shr 8) and 0xFF)
  result[8+body.len+3] = uint8(c and 0xFF)

proc encodePng*(img: DynamicImage): ImageResult[seq[uint8]] =
  ## Non-interlaced encoder, filter type 0 (None). Supports L8/Rgb8/Rgba8/
  ## La8/L16/Rgb16/Rgba16/La16. Palette input must already be expanded.
  var colorType = 0'u8; var bitDepth = 8'u8
  var w, h: int
  var samples: seq[uint8] # packed 8/16-bit samples row-major
  var channels = 0
  case img.kind
  of dkLuma8:
    (colorType, bitDepth, channels) = (0'u8, 8'u8, 1)
    w = int(img.luma8.width); h = int(img.luma8.height)
    samples = newSeq[uint8](w*h)
    for i, p in img.luma8.pixels: samples[i] = p.data[0]
  of dkRgb8:
    (colorType, bitDepth, channels) = (2'u8, 8'u8, 3)
    w = int(img.rgb8.width); h = int(img.rgb8.height)
    samples = newSeq[uint8](w*h*3)
    for i, p in img.rgb8.pixels:
      samples[3*i]=p.data[0]; samples[3*i+1]=p.data[1]; samples[3*i+2]=p.data[2]
  of dkRgba8:
    (colorType, bitDepth, channels) = (6'u8, 8'u8, 4)
    w = int(img.rgba8.width); h = int(img.rgba8.height)
    samples = newSeq[uint8](w*h*4)
    for i, p in img.rgba8.pixels:
      samples[4*i]=p.data[0]; samples[4*i+1]=p.data[1]
      samples[4*i+2]=p.data[2]; samples[4*i+3]=p.data[3]
  of dkLumaA8:
    (colorType, bitDepth, channels) = (4'u8, 8'u8, 2)
    w = int(img.lumaA8.width); h = int(img.lumaA8.height)
    samples = newSeq[uint8](w*h*2)
    for i, p in img.lumaA8.pixels:
      samples[2*i]=p.data[0]; samples[2*i+1]=p.data[1]
  of dkLuma16:
    (colorType, bitDepth, channels) = (0'u8, 16'u8, 1)
    w = int(img.luma16.width); h = int(img.luma16.height)
    samples = newSeq[uint8](w*h*2)
    for i, p in img.luma16.pixels:
      samples[2*i]=uint8((p.data[0] shr 8) and 0xFF); samples[2*i+1]=uint8(p.data[0] and 0xFF)
  of dkRgb16:
    (colorType, bitDepth, channels) = (2'u8, 16'u8, 3)
    w = int(img.rgb16.width); h = int(img.rgb16.height)
    samples = newSeq[uint8](w*h*6)
    for i, p in img.rgb16.pixels:
      for c in 0..2:
        samples[6*i+2*c]=uint8((p.data[c] shr 8) and 0xFF)
        samples[6*i+2*c+1]=uint8(p.data[c] and 0xFF)
  of dkRgba16:
    (colorType, bitDepth, channels) = (6'u8, 16'u8, 4)
    w = int(img.rgba16.width); h = int(img.rgba16.height)
    samples = newSeq[uint8](w*h*8)
    for i, p in img.rgba16.pixels:
      for c in 0..3:
        samples[8*i+2*c]=uint8((p.data[c] shr 8) and 0xFF)
        samples[8*i+2*c+1]=uint8(p.data[c] and 0xFF)
  of dkLumaA16:
    (colorType, bitDepth, channels) = (4'u8, 16'u8, 2)
    w = int(img.lumaA16.width); h = int(img.lumaA16.height)
    samples = newSeq[uint8](w*h*4)
    for i, p in img.lumaA16.pixels:
      for c in 0..1:
        samples[4*i+2*c]=uint8((p.data[c] shr 8) and 0xFF)
        samples[4*i+2*c+1]=uint8(p.data[c] and 0xFF)
  else:
    return err[seq[uint8]](unsupportedError(ukColor,
      "png: encode this DynamicImage variant via toRgba8/toRgb8/toLuma8 first"))
  let rowBytes = w * channels * (if bitDepth == 16: 2 else: 1)
  var raw = newSeq[uint8](h * (rowBytes + 1))
  for y in 0..<h:
    raw[y*(rowBytes+1)] = 0 # filter None
    for i in 0..<rowBytes: raw[y*(rowBytes+1)+1+i] = samples[y*rowBytes+i]
  let comp = deflateZlib(raw)
  if not comp.ok: return err[seq[uint8]](comp.err)
  var output = @PngSig
  var ihdr = newSeq[uint8](13)
  ihdr[0]=uint8((w shr 24) and 0xFF); ihdr[1]=uint8((w shr 16) and 0xFF)
  ihdr[2]=uint8((w shr 8) and 0xFF); ihdr[3]=uint8(w and 0xFF)
  ihdr[4]=uint8((h shr 24) and 0xFF); ihdr[5]=uint8((h shr 16) and 0xFF)
  ihdr[6]=uint8((h shr 8) and 0xFF); ihdr[7]=uint8(h and 0xFF)
  ihdr[8]=bitDepth; ihdr[9]=colorType
  output.add(encodeChunk([uint8('I'),uint8('H'),uint8('D'),uint8('R')], ihdr))
  output.add(encodeChunk([uint8('I'),uint8('D'),uint8('A'),uint8('T')], comp.value))
  output.add(encodeChunk([uint8('I'),uint8('E'),uint8('N'),uint8('D')], @[]))
  ok(output)
