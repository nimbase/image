## JPEG baseline encoder (pure Nim). Matches jpgdec.nim decoder.
## Standard Annex K Huffman tables + IJG quantization scaling.
## Supports Rgb8 (4:4:4 / 4:2:0) and Luma8.
import std/math
import ../color
import ../error
import ../buffer
import ../dynamic
import ../simd

const
  LumaQBase = [16,11,10,16,24,40,51,61,12,12,14,19,26,58,60,55,
    14,13,16,24,40,57,69,56,14,17,22,29,51,87,80,62,
    18,22,37,56,68,109,103,77,24,35,55,64,81,104,113,92,
    49,64,78,87,103,121,120,101,72,92,95,98,112,100,103,99]
  ChromaQBase = [17,18,24,47,99,99,99,99,18,21,26,66,99,99,99,99,
    24,26,56,99,99,99,99,99,47,66,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,
    99,99,99,99,99,99,99,99,99,99,99,99,99,99,99,99]
  DcLumaBits = [0,1,5,1,1,1,1,1,1,0,0,0,0,0,0,0]
  DcLumaVals = [0,1,2,3,4,5,6,7,8,9,10,11]
  DcChromaBits = [0,3,1,1,1,1,1,1,1,1,1,0,0,0,0,0]
  DcChromaVals = [0,1,2,3,4,5,6,7,8,9,10,11]
  AcLumaBits = [0,2,1,3,3,2,4,3,5,5,4,4,0,0,1,125]
  AcLumaVals = [0x01,0x02,0x03,0x00,0x04,0x11,0x05,0x12,0x21,0x31,0x41,
    0x06,0x13,0x51,0x61,0x07,0x22,0x71,0x14,0x32,0x81,0x91,0xA1,
    0x08,0x23,0x42,0xB1,0xC1,0x15,0x52,0xD1,0xF0,0x24,0x33,0x62,
    0x72,0x82,0x09,0x0A,0x16,0x17,0x18,0x19,0x1A,0x25,0x26,0x27,
    0x28,0x29,0x2A,0x34,0x35,0x36,0x37,0x38,0x39,0x3A,0x43,0x44,
    0x45,0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,0x56,0x57,0x58,
    0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,0x73,0x74,
    0x75,0x76,0x77,0x78,0x79,0x7A,0x83,0x84,0x85,0x86,0x87,0x88,
    0x89,0x8A,0x92,0x93,0x94,0x95,0x96,0x97,0x98,0x99,0x9A,0xA2,
    0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,0xB3,0xB4,0xB5,
    0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,0xC6,0xC7,0xC8,
    0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,0xD9,0xDA,0xE1,
    0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF1,0xF2,0xF3,
    0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA]
  AcChromaBits = [0,2,1,2,4,4,3,4,7,5,4,4,0,1,2,119]
  AcChromaVals = [0x00,0x01,0x02,0x03,0x11,0x04,0x05,0x21,0x31,0x06,
    0x12,0x41,0x51,0x07,0x61,0x71,0x13,0x22,0x32,0x81,0x08,0x14,
    0x42,0x91,0xA1,0xB1,0xC1,0x09,0x23,0x33,0x52,0xF0,0x15,0x62,
    0x72,0xD1,0x0A,0x16,0x24,0x34,0xE1,0x25,0xF1,0x17,0x18,0x19,
    0x1A,0x26,0x27,0x28,0x29,0x2A,0x35,0x36,0x37,0x38,0x39,0x3A,
    0x43,0x44,0x45,0x46,0x47,0x48,0x49,0x4A,0x53,0x54,0x55,0x56,
    0x57,0x58,0x59,0x5A,0x63,0x64,0x65,0x66,0x67,0x68,0x69,0x6A,
    0x73,0x74,0x75,0x76,0x77,0x78,0x79,0x7A,0x82,0x83,0x84,0x85,
    0x86,0x87,0x88,0x89,0x8A,0x92,0x93,0x94,0x95,0x96,0x97,0x98,
    0x99,0x9A,0xA2,0xA3,0xA4,0xA5,0xA6,0xA7,0xA8,0xA9,0xAA,0xB2,
    0xB3,0xB4,0xB5,0xB6,0xB7,0xB8,0xB9,0xBA,0xC2,0xC3,0xC4,0xC5,
    0xC6,0xC7,0xC8,0xC9,0xCA,0xD2,0xD3,0xD4,0xD5,0xD6,0xD7,0xD8,
    0xD9,0xDA,0xE2,0xE3,0xE4,0xE5,0xE6,0xE7,0xE8,0xE9,0xEA,0xF2,
    0xF3,0xF4,0xF5,0xF6,0xF7,0xF8,0xF9,0xFA]

type HuffCode = object
  code: array[256, int]
  size: array[256, int]

proc makeHuffCode(bits: array[16, int], vals: openArray[int]): HuffCode =
  var code = 0
  var k = 0
  for l in 1..16:
    for _ in 0..<bits[l-1]:
      result.code[vals[k]] = code
      result.size[vals[k]] = l
      inc(code); inc(k)
    code = code shl 1

proc scaleQuant(base: array[64, int], quality: int): array[64, int] =
  let q = clamp(quality, 1, 100)
  let scale = if q < 50: 5000 div q else: 200 - 2 * q
  for i in 0..63:
    result[i] = clamp((base[i] * scale + 50) div 100, 1, 255)

var UnzigzagEnc {.global.}: array[64, int]

proc initZigzagEnc() =
  var i = 0
  for s in 0..14:
    if s mod 2 == 0:
      var r = min(s, 7)
      while r >= max(0, s - 7):
        UnzigzagEnc[i] = r * 8 + (s - r)
        inc i; dec r
    else:
      var r = max(0, s - 7)
      while r <= min(s, 7):
        UnzigzagEnc[i] = r * 8 + (s - r)
        inc i; inc r

initZigzagEnc()

proc fdctBlock(px: array[64, float64]): array[64, float64] =
  fdctBlockSimd(px)

type BitWriter = object
  data: seq[uint8]
  buf: uint32
  nbits: int

proc emitBits(w: var BitWriter, code, size: int) =
  w.buf = (w.buf shl size) or uint32(code)
  w.nbits += size
  while w.nbits >= 8:
    w.nbits -= 8
    let b = uint8((w.buf shr w.nbits) and 0xFF)
    w.data.add(b)
    if b == 0xFF: w.data.add(0x00)

proc flushBits(w: var BitWriter) =
  if w.nbits > 0:
    let b = uint8(((w.buf shl (8 - w.nbits)) and 0xFF))
    w.data.add(b)
    if b == 0xFF: w.data.add(0x00)
    w.buf = 0; w.nbits = 0

proc category(v: int): int =
  var a = abs(v)
  var n = 0
  while a > 0: inc(n); a = a shr 1
  n

proc emitCategory(w: var BitWriter, dcCode: HuffCode, v: int) =
  let s = category(v)
  w.emitBits(dcCode.code[s], dcCode.size[s])
  if s > 0:
    let bits = if v >= 0: v else: v + (1 shl s) - 1
    w.emitBits(bits, s)

proc encodeBlock(w: var BitWriter, zz: array[64, int], dcCode: HuffCode,
    acCode: HuffCode, prevDc: var int) =
  let diff = zz[0] - prevDc
  prevDc = zz[0]
  w.emitCategory(dcCode, diff)
  var zeroRun = 0
  for k in 1..63:
    if zz[k] == 0:
      inc(zeroRun)
    else:
      while zeroRun >= 16:
        w.emitBits(acCode.code[0xF0], acCode.size[0xF0])
        zeroRun -= 16
      let rs = (zeroRun shl 4) or category(zz[k])
      w.emitBits(acCode.code[rs], acCode.size[rs])
      let s = category(zz[k])
      let bits = if zz[k] >= 0: zz[k] else: zz[k] + (1 shl s) - 1
      w.emitBits(bits, s)
      zeroRun = 0
  if zeroRun > 0:
    w.emitBits(acCode.code[0x00], acCode.size[0x00])

proc seg(tag: uint8, body: openArray[uint8]): seq[uint8] =
  result = @[0xFF'u8, tag, uint8(((body.len+2) shr 8) and 0xFF),
    uint8((body.len+2) and 0xFF)]
  for b in body: result.add(b)

proc rgbToYcbcr(r, g, b: uint8): tuple[y, cb, cr: uint8] =
  let fr = float64(r); let fg = float64(g); let fb = float64(b)
  (uint8(clamp(int(0.299*fr + 0.587*fg + 0.114*fb + 0.5), 0, 255)),
   uint8(clamp(int(-0.168736*fr - 0.331264*fg + 0.5*fb + 128.5), 0, 255)),
   uint8(clamp(int(0.5*fr - 0.418688*fg - 0.081312*fb + 128.5), 0, 255)))

proc encodeJpeg*(img: DynamicImage, quality = 90,
    subsample = true): ImageResult[seq[uint8]] =
  if quality < 1 or quality > 100:
    return err[seq[uint8]](paramError(pkGeneric, "jpeg: quality 1..100"))
  var isGray = false
  var w, h: int
  var rgb: seq[Rgb[uint8]] = @[]
  var gray: seq[Luma[uint8]] = @[]
  case img.kind
  of dkRgb8:
    w = int(img.rgb8.width); h = int(img.rgb8.height); rgb = img.rgb8.pixels
  of dkRgba8:
    w = int(img.rgba8.width); h = int(img.rgba8.height)
    rgb = newSeq[Rgb[uint8]](img.rgba8.pixels.len)
    for i, p in img.rgba8.pixels:
      rgb[i] = Rgb[uint8](data: [p.data[0], p.data[1], p.data[2]])
  of dkLuma8:
    isGray = true
    w = int(img.luma8.width); h = int(img.luma8.height); gray = img.luma8.pixels
  else:
    let c = img.toRgb8()
    w = int(c.width); h = int(c.height); rgb = c.pixels
  if w == 0 or h == 0:
    return err[seq[uint8]](paramError(pkDimensionMismatch, "jpeg: empty"))
  if w > 65535 or h > 65535:
    return err[seq[uint8]](limitError(lkDimensionError, "jpeg: too large"))
  let qY = scaleQuant(LumaQBase, quality)
  let qC = scaleQuant(ChromaQBase, quality)
  let dcY = makeHuffCode(DcLumaBits, DcLumaVals)
  let dcC = makeHuffCode(DcChromaBits, DcChromaVals)
  let acY = makeHuffCode(AcLumaBits, AcLumaVals)
  let acC = makeHuffCode(AcChromaBits, AcChromaVals)
  var output = @[0xFF'u8, 0xD8]
  # JFIF APP0
  output.add(seg(0xE0, [uint8('J'),uint8('F'),uint8('I'),uint8('F'),0,1,2,0,0,1,0,1,0,0]))
  # DQT: two tables (8-bit)
  var dqt: seq[uint8] = @[0]
  for i in 0..63: dqt.add(uint8(qY[i]))
  dqt.add(1)
  for i in 0..63: dqt.add(uint8(qC[i]))
  output.add(seg(0xDB, dqt))
  # SOF0
  let nc = if isGray: 1 else: 3
  var sof: seq[uint8] = @[8, uint8((h shr 8) and 0xFF), uint8(h and 0xFF),
    uint8((w shr 8) and 0xFF), uint8(w and 0xFF), uint8(nc)]
  let useSub = subsample and not isGray
  if isGray:
    sof.add([1'u8, 0x11, 0])
  elif useSub:
    sof.add([1'u8, 0x22, 0, 2, 0x11, 1, 3, 0x11, 1])
  else:
    sof.add([1'u8, 0x11, 0, 2, 0x11, 1, 3, 0x11, 1])
  output.add(seg(0xC0, sof))
  # DHT: 4 tables
  var dht: seq[uint8] = @[]
  proc addTable(tc, th: int, bits: array[16, int], vals: openArray[int]) =
    dht.add(uint8((tc shl 4) or th))
    for b in bits: dht.add(uint8(b))
    for v in vals: dht.add(uint8(v))
  addTable(0, 0, DcLumaBits, DcLumaVals)
  addTable(0, 1, DcChromaBits, DcChromaVals)
  addTable(1, 0, AcLumaBits, AcLumaVals)
  addTable(1, 1, AcChromaBits, AcChromaVals)
  output.add(seg(0xC4, dht))
  # SOS
  var sos: seq[uint8]
  if isGray: sos = @[1, 1, 0x00, 0, 63, 0]
  else: sos = @[3, 1, 0x00, 2, 0x11, 3, 0x11, 0, 63, 0]
  output.add(seg(0xDA, sos))
  # entropy data: planes
  var yPlane = newSeq[uint8](w*h)
  var cbPlane = newSeq[uint8](w*h)
  var crPlane = newSeq[uint8](w*h)
  var gPlane = newSeq[uint8](w*h)
  if isGray:
    for i, p in gray: gPlane[i] = p.data[0]
  else:
    for i, p in rgb:
      let (yy, cb, cr) = rgbToYcbcr(p.data[0], p.data[1], p.data[2])
      yPlane[i] = yy; cbPlane[i] = cb; crPlane[i] = cr
  var writer = BitWriter()
  proc sampBlock(plane: seq[uint8], bx, by, bw, bh, stride: int): array[64, float64] =
    for y in 0..7:
      for x in 0..7:
        let sx = min(bx*8+x, bw-1); let sy = min(by*8+y, bh-1)
        result[y*8+x] = float64(plane[sy*stride+sx]) - 128.0
  proc quantZig(d: array[64, float64], qtab: array[64, int]): array[64, int] =
    ## FDCT output d is natural order; qtab is DQT (scan) order.
    for k in 0..63:
      result[k] = int(floor(d[UnzigzagEnc[k]] / float64(qtab[k]) + 0.5))
  if isGray:
    let mcuX = (w + 7) div 8; let mcuY = (h + 7) div 8
    var prev = 0
    for my in 0..<mcuY:
      for mx in 0..<mcuX:
        let d = fdctBlock(sampBlock(gPlane, mx, my, w, h, w))
        encodeBlock(writer, quantZig(d, qY), dcY, acY, prev)
  else:
    let hY = if useSub: 2 else: 1
    let vY = if useSub: 2 else: 1
    let mcuX = (w + 8*hY - 1) div (8*hY)
    let mcuY = (h + 8*vY - 1) div (8*vY)
    var prevY = 0; var prevCb = 0; var prevCr = 0
    # downsample chroma for 4:2:0 by box average
    var cbS = cbPlane; var crS = crPlane
    var sw = w; var sh = h
    if useSub:
      sw = (w + 1) div 2; sh = (h + 1) div 2
      cbS = newSeq[uint8](sw*sh); crS = newSeq[uint8](sw*sh)
      for y in 0..<sh:
        for x in 0..<sw:
          var sCb = 0; var sCr = 0; var n = 0
          for dy in 0..1:
            for dx in 0..1:
              let sx = x*2+dx; let sy = y*2+dy
              if sx < w and sy < h:
                sCb += int(cbPlane[sy*w+sx]); sCr += int(crPlane[sy*w+sx]); inc(n)
          cbS[y*sw+x] = uint8((sCb + n div 2) div n)
          crS[y*sw+x] = uint8((sCr + n div 2) div n)
    for my in 0..<mcuY:
      for mx in 0..<mcuX:
        for by in 0..<vY:
          for bx in 0..<hY:
            let d = fdctBlock(sampBlock(yPlane, mx*hY+bx, my*vY+by, w, h, w))
            encodeBlock(writer, quantZig(d, qY), dcY, acY, prevY)
        block:
          let stride = if useSub: sw else: w
          let pw = if useSub: sw else: w
          let ph = if useSub: sh else: h
          let d = fdctBlock(sampBlock(cbS, mx, my, pw, ph, stride))
          encodeBlock(writer, quantZig(d, qC), dcC, acC, prevCb)
        block:
          let stride = if useSub: sw else: w
          let pw = if useSub: sw else: w
          let ph = if useSub: sh else: h
          let d = fdctBlock(sampBlock(crS, mx, my, pw, ph, stride))
          encodeBlock(writer, quantZig(d, qC), dcC, acC, prevCr)
  writer.flushBits()
  for b in writer.data: output.add(b)
  output.add([0xFF'u8, 0xD9])
  ok(output)
