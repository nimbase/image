## ICO codec — references/image/src/codecs/ico/ (decoder 705, encoder)
## ICONDIR + entries; payload is PNG (preferred) or BMP DIB (height doubled
## + trailing AND mask). Thin wrapper over png/bmp codecs.
import ../color
import ../error
import ../buffer
import ../dynamic
import ./png
import ./bmp

type
  IcoEntry* = object
    width*, height*: uint16 # 0 means 256
    colorCount*: uint8
    planes*, bitCount*: uint16
    bytesInRes*: uint32
    imageOffset*: uint32

proc parseIcoDir(data: seq[uint8]): ImageResult[seq[IcoEntry]] =
  if data.len < 6:
    return err[seq[IcoEntry]](decodingError("ico: too short"))
  let reserved = uint16(data[0]) or (uint16(data[1]) shl 8)
  let typ = uint16(data[2]) or (uint16(data[3]) shl 8)
  let count = int(uint16(data[4]) or (uint16(data[5]) shl 8))
  if reserved != 0 or typ != 1 or count == 0:
    return err[seq[IcoEntry]](decodingError("ico: bad header"))
  if data.len < 6 + count * 16:
    return err[seq[IcoEntry]](decodingError("ico: truncated entries"))
  var entries: seq[IcoEntry] = @[]
  for i in 0..<count:
    let o = 6 + i * 16
    let w = uint16(if data[o] == 0: 256 else: int(data[o]))
    let h = uint16(if data[o+1] == 0: 256 else: int(data[o+1]))
    entries.add(IcoEntry(width: w, height: h, colorCount: data[o+2],
      planes: uint16(data[o+4]) or (uint16(data[o+5]) shl 8),
      bitCount: uint16(data[o+6]) or (uint16(data[o+7]) shl 8),
      bytesInRes: uint32(data[o+8]) or (uint32(data[o+9]) shl 8) or
        (uint32(data[o+10]) shl 16) or (uint32(data[o+11]) shl 24),
      imageOffset: uint32(data[o+12]) or (uint32(data[o+13]) shl 8) or
        (uint32(data[o+14]) shl 16) or (uint32(data[o+15]) shl 24)))
  ok(entries)

proc isPngPayload(data: openArray[uint8]): bool =
  data.len >= 8 and data[0]==137 and data[1]==80 and data[2]==78 and
    data[3]==71 and data[4]==13 and data[5]==10 and data[6]==26 and data[7]==10

proc decodeBmpIcoPayload*(payload: seq[uint8]): ImageResult[DynamicImage] =
  ## ICO BMP payloads: DIB header (no file header), height doubled (XOR+AND),
  ## followed by trailing AND mask (1-bit transparency, bottom-up rows).
  if payload.len < 4:
    return err[DynamicImage](decodingError("ico: truncated bmp"))
  let dibSize = int(uint32(payload[0]) or (uint32(payload[1]) shl 8) or
    (uint32(payload[2]) shl 16) or (uint32(payload[3]) shl 24))
  if dibSize != 12 and dibSize notin [40, 52, 56, 108, 124]:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "ico: DIB size " & $dibSize))
  var wAct, hAct: int
  var bpp: uint16
  var heightIsNeg = false
  if dibSize == 12:
    if payload.len < 26: return err[DynamicImage](decodingError("ico: truncated core"))
    wAct = int(uint16(payload[4]) or (uint16(payload[5]) shl 8))
    var hh = int(uint16(payload[6]) or (uint16(payload[7]) shl 8))
    bpp = uint16(payload[10]) or (uint16(payload[11]) shl 8)
    hAct = hh div 2
  else:
    if payload.len < 40: return err[DynamicImage](decodingError("ico: truncated info"))
    wAct = int(int32(uint32(payload[4]) or (uint32(payload[5]) shl 8) or
      (uint32(payload[6]) shl 16) or (uint32(payload[7]) shl 24)))
    var hh = int(int32(uint32(payload[8]) or (uint32(payload[9]) shl 8) or
      (uint32(payload[10]) shl 16) or (uint32(payload[11]) shl 24)))
    if hh < 0: heightIsNeg = true; hh = -hh
    bpp = uint16(payload[14]) or (uint16(payload[15]) shl 8)
    hAct = hh div 2
  if wAct <= 0 or hAct <= 0:
    return err[DynamicImage](decodingError("ico: bad bmp dimensions"))
  # Patch a copy: halve DIB height, prepend file header.
  var patched = payload
  if dibSize == 12:
    patched[6] = uint8(hAct and 0xFF); patched[7] = uint8((hAct shr 8) and 0xFF)
  else:
    let hv = if heightIsNeg: -hAct else: hAct
    let hu = uint32(hv)
    patched[8]=uint8(hu and 0xFF); patched[9]=uint8((hu shr 8) and 0xFF)
    patched[10]=uint8((hu shr 16) and 0xFF); patched[11]=uint8((hu shr 24) and 0xFF)
  # Locate pixel data: DIB + masks + palette.
  var compression = 0'u32
  if dibSize >= 40 and payload.len >= 34:
    compression = uint32(payload[16]) or (uint32(payload[17]) shl 8) or
      (uint32(payload[18]) shl 16) or (uint32(payload[19]) shl 24)
  var masksLen = 0
  if dibSize == 12: discard
  elif compression == 3 or compression == 6:
    masksLen = 12
    if dibSize >= 56 or compression == 6: masksLen = 16
  elif dibSize > 40:
    # V4/V5 carry masks inline regardless; conservative: no extra
    discard
  var numColors = 0
  if bpp <= 8:
    var colorsUsed = 0'u32
    if dibSize >= 40 and payload.len >= 50:
      colorsUsed = uint32(payload[32]) or (uint32(payload[33]) shl 8) or
        (uint32(payload[34]) shl 16) or (uint32(payload[35]) shl 24)
    numColors = if colorsUsed != 0: int(colorsUsed) else: 1 shl int(bpp)
  let entrySize = if dibSize == 12: 3 else: 4
  let pixOffInPayload = dibSize + masksLen + numColors * entrySize
  var full = newSeq[uint8](14 + payload.len)
  full[0] = uint8('B'); full[1] = uint8('M')
  let fs = uint32(full.len)
  full[2]=uint8(fs and 0xFF); full[3]=uint8((fs shr 8) and 0xFF)
  full[4]=uint8((fs shr 16) and 0xFF); full[5]=uint8((fs shr 24) and 0xFF)
  let dataOff = uint32(14 + pixOffInPayload)
  full[10]=uint8(dataOff and 0xFF); full[11]=uint8((dataOff shr 8) and 0xFF)
  full[12]=uint8((dataOff shr 16) and 0xFF); full[13]=uint8((dataOff shr 24) and 0xFF)
  for i, b in patched: full[14+i] = b
  let dr = decodeBmp(full)
  if not dr.ok: return dr
  # AND mask: follows the doubled-height XOR pixel data in payload
  let rowStride =
    if bpp >= 8: ((int(bpp) * wAct + 31) div 32) * 4
    else: ((wAct * int(bpp) + 31) div 32) * 4
  let andStride = ((wAct + 31) div 32) * 4
  let andOff = pixOffInPayload + rowStride * hAct * 2
  if andOff + andStride * hAct > payload.len:
    return dr # no AND mask present; opaque
  proc andBit(x, y: int): bool =
    # AND mask rows are bottom-up always
    let yy = hAct - 1 - y
    let b = payload[andOff + yy * andStride + x div 8]
    ((b shr (7 - (x mod 8))) and 1) == 1
  case dr.value.kind
  of dkRgb8:
    let s = dr.value.rgb8
    var px = newSeq[Rgba[uint8]](s.pixels.len)
    for y in 0..<hAct:
      for x in 0..<wAct:
        let p = s.pixels[y*wAct+x]
        px[y*wAct+x] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2],
          if andBit(x, y): 0'u8 else: 255'u8])
    ok(DynamicImage(kind: dkRgba8, rgba8:
      RgbaImage(width: uint32(wAct), height: uint32(hAct), pixels: move(px))))
  of dkRgba8:
    var s = dr.value.rgba8
    for y in 0..<hAct:
      for x in 0..<wAct:
        if andBit(x, y): s.pixels[y*wAct+x].data[3] = 0
    ok(DynamicImage(kind: dkRgba8, rgba8: s))
  else:
    dr

proc decodeIcoEntry(data: seq[uint8],
    e: IcoEntry): ImageResult[DynamicImage] =
  let off = int(e.imageOffset); let n = int(e.bytesInRes)
  if off + n > data.len or n == 0:
    return err[DynamicImage](decodingError("ico: entry OOB"))
  let payload = data[off..<off+n]
  if isPngPayload(payload):
    return decodePng(payload)
  decodeBmpIcoPayload(payload)

proc decodeIcoAll*(data: seq[uint8]): ImageResult[seq[DynamicImage]] =
  let er = parseIcoDir(data)
  if not er.ok: return err[seq[DynamicImage]](er.err)
  var images: seq[DynamicImage] = @[]
  for e in er.value:
    let r = decodeIcoEntry(data, e)
    if not r.ok: return err[seq[DynamicImage]](r.err)
    images.add(r.value)
  if images.len == 0:
    return err[seq[DynamicImage]](decodingError("ico: no images"))
  ok(images)

proc decodeIco*(data: seq[uint8]): ImageResult[DynamicImage] =
  ## Largest entry wins (closest to reference behavior for stills).
  let er = parseIcoDir(data)
  if not er.ok: return err[DynamicImage](er.err)
  var best = -1; var bestArea = -1
  for i, e in er.value:
    let area = int(e.width) * int(e.height)
    if area > bestArea: bestArea = area; best = i
  decodeIcoEntry(data, er.value[best])

proc encodeIco*(images: seq[DynamicImage]): ImageResult[seq[uint8]] =
  ## PNG-compressed entries (matches reference preference).
  if images.len == 0 or images.len > 65535:
    return err[seq[uint8]](paramError(pkGeneric, "ico: bad image count"))
  type Blob = tuple[w, h: int, bytes: seq[uint8]]
  var blobs: seq[Blob] = @[]
  for img in images:
    let (ww, hh) = img.dimensions()
    if ww == 0 or hh == 0 or ww > 256 or hh > 256:
      return err[seq[uint8]](paramError(pkDimensionMismatch, "ico: dimensions"))
    # normalize to RGBA8 for PNG payload
    let rgba = img.toRgba8()
    let norm = DynamicImage(kind: dkRgba8, rgba8: rgba)
    let er = encodePng(norm)
    if not er.ok: return err[seq[uint8]](er.err)
    blobs.add((int(ww), int(hh), er.value))
  var output = newSeq[uint8](6 + 16 * blobs.len)
  output[2] = 1; output[4] = uint8(blobs.len and 0xFF)
  output[5] = uint8((blobs.len shr 8) and 0xFF)
  var off = 6 + 16 * blobs.len
  for i, b in blobs:
    let o = 6 + i * 16
    output[o] = uint8(if b.w == 256: 0 else: b.w)
    output[o+1] = uint8(if b.h == 256: 0 else: b.h)
    # colorCount/planes/bitCount left 0 for PNG entries
    let n = uint32(b.bytes.len)
    output[o+8]=uint8(n and 0xFF); output[o+9]=uint8((n shr 8) and 0xFF)
    output[o+10]=uint8((n shr 16) and 0xFF); output[o+11]=uint8((n shr 24) and 0xFF)
    output[o+12]=uint8(off and 0xFF); output[o+13]=uint8((off shr 8) and 0xFF)
    output[o+14]=uint8((off shr 16) and 0xFF); output[o+15]=uint8((off shr 24) and 0xFF)
    off += b.bytes.len
  for b in blobs:
    for bte in b.bytes: output.add(bte)
  ok(output)
