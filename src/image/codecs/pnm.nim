## PNM codec — references/image/src/codecs/pnm/ (decoder 1582, encoder 774, header 366)
## Supports P1/P4 bitmap, P2/P5 graymap, P3/P6 pixmap, P7 PAM (subset).
import std/strutils
import ../color
import ../error
import ../buffer
import ../dynamic

type
  PnmEncoding* = enum peAscii, peBinary
  PnmSubtype* = enum
    psBitmap, psGraymap, psPixmap, psArbitrary
  PnmHeader* = object
    subtype*: PnmSubtype
    encoding*: PnmEncoding
    width*, height*: uint32
    maxval*: uint32
    depth*: uint32
    tupltype*: string

func isWs(c: char): bool = c in {' ', '\t', '\n', '\r', '\x0B', '\x0C'}

proc skipWsComments(data: openArray[uint8], pos: var int) =
  while pos < data.len:
    let c = char(data[pos])
    if c == '#':
      while pos < data.len and char(data[pos]) notin {'\n', '\r'}: inc pos
    elif isWs(c):
      inc pos
    else: break

proc readToken(data: openArray[uint8], pos: var int): string =
  skipWsComments(data, pos)
  let start = pos
  while pos < data.len and not isWs(char(data[pos])) and char(data[pos]) != '#':
    inc pos
  result = newString(pos - start)
  for i in 0..<pos-start: result[i] = char(data[start+i])

proc parsePnmHeader*(data: openArray[uint8]): ImageResult[tuple[h: PnmHeader, bodyOff: int]] =
  if data.len < 2 or char(data[0]) != 'P':
    return err[tuple[h: PnmHeader, bodyOff: int]](decodingError("pnm: bad magic"))
  let magic = char(data[1])
  var pos = 2
  var h = PnmHeader()
  case magic
  of '1': h = PnmHeader(subtype: psBitmap, encoding: peAscii)
  of '4': h = PnmHeader(subtype: psBitmap, encoding: peBinary)
  of '2': h = PnmHeader(subtype: psGraymap, encoding: peAscii)
  of '5': h = PnmHeader(subtype: psGraymap, encoding: peBinary)
  of '3': h = PnmHeader(subtype: psPixmap, encoding: peAscii)
  of '6': h = PnmHeader(subtype: psPixmap, encoding: peBinary)
  of '7':
    # PAM text header ending with ENDHDR
    var width = 0'u32; var height = 0'u32; var depth = 0'u32; var maxval = 0'u32
    var tupl = ""
    # find ENDHDR line
    var hdrEnd = -1
    var i = pos
    while i < data.len:
      skipWsComments(data, i)
      let t = readToken(data, i)
      if t == "ENDHDR": hdrEnd = i; break
      elif t == "WIDTH": width = uint32(parseInt(readToken(data, i)))
      elif t == "HEIGHT": height = uint32(parseInt(readToken(data, i)))
      elif t == "DEPTH": depth = uint32(parseInt(readToken(data, i)))
      elif t == "MAXVAL": maxval = uint32(parseInt(readToken(data, i)))
      elif t == "TUPLTYPE": tupl = readToken(data, i)
      elif t == "": break
      else: discard
    if hdrEnd < 0:
      return err[tuple[h: PnmHeader, bodyOff: int]](decodingError("pnm: PAM missing ENDHDR"))
    # single whitespace after ENDHDR is part of header
    if hdrEnd < data.len and isWs(char(data[hdrEnd])): inc hdrEnd
    h = PnmHeader(subtype: psArbitrary, encoding: peBinary, width: width,
      height: height, maxval: maxval, depth: depth, tupltype: tupl)
    return ok((h, hdrEnd))
  else:
    return err[tuple[h: PnmHeader, bodyOff: int]](decodingError("pnm: unknown magic P" & $magic))
  try:
    h.width = uint32(parseInt(readToken(data, pos)))
    h.height = uint32(parseInt(readToken(data, pos)))
    if h.subtype in {psGraymap, psPixmap}:
      h.maxval = uint32(parseInt(readToken(data, pos)))
      if h.maxval == 0 or h.maxval > 65535:
        return err[tuple[h: PnmHeader, bodyOff: int]](decodingError("pnm: bad maxval"))
    if h.encoding == peBinary:
      # single whitespace after maxval belongs to header
      if pos < data.len and isWs(char(data[pos])): inc pos
  except ValueError:
    return err[tuple[h: PnmHeader, bodyOff: int]](decodingError("pnm: bad header ints"))
  ok((h, pos))

proc scaleToU8(v, maxval: uint32): uint8 =
  if maxval == 255: uint8(v)
  else: uint8((v * 255 + maxval div 2) div maxval)

proc scaleToU16(v, maxval: uint32): uint16 =
  if maxval == 65535: uint16(v)
  else: uint16((v * 65535 + maxval div 2) div maxval)

proc decodePnm*(data: seq[uint8]): ImageResult[DynamicImage] =
  let hr = parsePnmHeader(data)
  if not hr.ok: return err[DynamicImage](hr.err)
  let (h, bodyOff) = hr.value
  if h.width == 0 or h.height == 0:
    return err[DynamicImage](decodingError("pnm: zero dimension"))
  let n = int(h.width) * int(h.height)
  case h.subtype
  of psBitmap:
    var px = newSeq[Luma[uint8]](n)
    if h.encoding == peAscii:
      var pos = bodyOff
      for i in 0..<n:
        let t = readToken(data, pos)
        if t == "": return err[DynamicImage](decodingError("pnm: truncated bitmap"))
        px[i] = Luma[uint8](data: [if t == "1": 255'u8 else: 0'u8])
    else:
      let rowBytes = (int(h.width) + 7) div 8
      if bodyOff + rowBytes * int(h.height) > data.len:
        return err[DynamicImage](decodingError("pnm: truncated bitmap"))
      for y in 0..<int(h.height):
        for x in 0..<int(h.width):
          let b = data[bodyOff + y * rowBytes + x div 8]
          let bit = (b shr (7 - (x mod 8))) and 1
          px[y * int(h.width) + x] = Luma[uint8](data: [if bit == 1: 255'u8 else: 0'u8])
    ok(DynamicImage(kind: dkLuma8, luma8: GrayImage(width: h.width, height: h.height, pixels: move(px))))
  of psGraymap:
    if h.maxval <= 255:
      var px = newSeq[Luma[uint8]](n)
      if h.encoding == peAscii:
        var pos = bodyOff
        for i in 0..<n:
          let t = readToken(data, pos)
          if t == "": return err[DynamicImage](decodingError("pnm: truncated graymap"))
          px[i] = Luma[uint8](data: [scaleToU8(uint32(parseInt(t)), h.maxval)])
      else:
        if bodyOff + n > data.len:
          return err[DynamicImage](decodingError("pnm: truncated graymap"))
        for i in 0..<n: px[i] = Luma[uint8](data: [scaleToU8(uint32(data[bodyOff+i]), h.maxval)])
      ok(DynamicImage(kind: dkLuma8, luma8: GrayImage(width: h.width, height: h.height, pixels: move(px))))
    else:
      var px = newSeq[Luma[uint16]](n)
      if h.encoding == peAscii:
        var pos = bodyOff
        for i in 0..<n:
          let t = readToken(data, pos)
          if t == "": return err[DynamicImage](decodingError("pnm: truncated graymap"))
          px[i] = Luma[uint16](data: [scaleToU16(uint32(parseInt(t)), h.maxval)])
      else:
        if bodyOff + n * 2 > data.len:
          return err[DynamicImage](decodingError("pnm: truncated graymap"))
        for i in 0..<n:
          let v = (uint32(data[bodyOff+2*i]) shl 8) or uint32(data[bodyOff+2*i+1])
          px[i] = Luma[uint16](data: [scaleToU16(v, h.maxval)])
      ok(DynamicImage(kind: dkLuma16, luma16: Gray16Image(width: h.width, height: h.height, pixels: move(px))))
  of psPixmap:
    if h.maxval <= 255:
      var px = newSeq[Rgb[uint8]](n)
      if h.encoding == peAscii:
        var pos = bodyOff
        for i in 0..<n:
          let rs = readToken(data, pos); let gs = readToken(data, pos); let bs = readToken(data, pos)
          if bs == "": return err[DynamicImage](decodingError("pnm: truncated pixmap"))
          px[i] = Rgb[uint8](data: [scaleToU8(uint32(parseInt(rs)), h.maxval),
            scaleToU8(uint32(parseInt(gs)), h.maxval), scaleToU8(uint32(parseInt(bs)), h.maxval)])
      else:
        if bodyOff + n * 3 > data.len:
          return err[DynamicImage](decodingError("pnm: truncated pixmap"))
        for i in 0..<n:
          px[i] = Rgb[uint8](data: [scaleToU8(uint32(data[bodyOff+3*i]), h.maxval),
            scaleToU8(uint32(data[bodyOff+3*i+1]), h.maxval),
            scaleToU8(uint32(data[bodyOff+3*i+2]), h.maxval)])
      ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: h.width, height: h.height, pixels: move(px))))
    else:
      var px = newSeq[Rgb[uint16]](n)
      if h.encoding == peAscii:
        var pos = bodyOff
        for i in 0..<n:
          let rs = readToken(data, pos); let gs = readToken(data, pos); let bs = readToken(data, pos)
          if bs == "": return err[DynamicImage](decodingError("pnm: truncated pixmap"))
          px[i] = Rgb[uint16](data: [scaleToU16(uint32(parseInt(rs)), h.maxval),
            scaleToU16(uint32(parseInt(gs)), h.maxval), scaleToU16(uint32(parseInt(bs)), h.maxval)])
      else:
        if bodyOff + n * 6 > data.len:
          return err[DynamicImage](decodingError("pnm: truncated pixmap"))
        for i in 0..<n:
          let r = (uint32(data[bodyOff+6*i]) shl 8) or uint32(data[bodyOff+6*i+1])
          let g = (uint32(data[bodyOff+6*i+2]) shl 8) or uint32(data[bodyOff+6*i+3])
          let b = (uint32(data[bodyOff+6*i+4]) shl 8) or uint32(data[bodyOff+6*i+5])
          px[i] = Rgb[uint16](data: [scaleToU16(r, h.maxval), scaleToU16(g, h.maxval), scaleToU16(b, h.maxval)])
      ok(DynamicImage(kind: dkRgb16, rgb16: Rgb16Image(width: h.width, height: h.height, pixels: move(px))))
  of psArbitrary:
    if h.depth == 1 and h.maxval <= 255:
      var px = newSeq[Luma[uint8]](n)
      if bodyOff + n > data.len:
        return err[DynamicImage](decodingError("pnm: truncated pam"))
      for i in 0..<n: px[i] = Luma[uint8](data: [scaleToU8(uint32(data[bodyOff+i]), h.maxval)])
      ok(DynamicImage(kind: dkLuma8, luma8: GrayImage(width: h.width, height: h.height, pixels: move(px))))
    elif h.depth == 3 and h.maxval <= 255:
      var px = newSeq[Rgb[uint8]](n)
      if bodyOff + n * 3 > data.len:
        return err[DynamicImage](decodingError("pnm: truncated pam"))
      for i in 0..<n:
        px[i] = Rgb[uint8](data: [data[bodyOff+3*i], data[bodyOff+3*i+1], data[bodyOff+3*i+2]])
      ok(DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: h.width, height: h.height, pixels: move(px))))
    elif h.depth == 4 and h.maxval <= 255:
      var px = newSeq[Rgba[uint8]](n)
      if bodyOff + n * 4 > data.len:
        return err[DynamicImage](decodingError("pnm: truncated pam"))
      for i in 0..<n:
        px[i] = Rgba[uint8](data: [data[bodyOff+4*i], data[bodyOff+4*i+1],
          data[bodyOff+4*i+2], data[bodyOff+4*i+3]])
      ok(DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: h.width, height: h.height, pixels: move(px))))
    else:
      err[DynamicImage](unsupportedError(ukColor, "pnm: PAM depth " & $h.depth & " maxval " & $h.maxval))

proc encodePnmGray8*(img: GrayImage): seq[uint8] =
  var hdr = "P5\n" & $img.width & " " & $img.height & "\n255\n"
  result = newSeq[uint8](hdr.len + img.pixels.len)
  for i, c in hdr: result[i] = uint8(c)
  for i, p in img.pixels: result[hdr.len + i] = p.data[0]

proc encodePnmRgb8*(img: RgbImage): seq[uint8] =
  var hdr = "P6\n" & $img.width & " " & $img.height & "\n255\n"
  result = newSeq[uint8](hdr.len + img.pixels.len * 3)
  for i, c in hdr: result[i] = uint8(c)
  var off = hdr.len
  for p in img.pixels:
    result[off] = p.data[0]; result[off+1] = p.data[1]; result[off+2] = p.data[2]
    off += 3
