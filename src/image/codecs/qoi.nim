## QOI codec — references/image/src/codecs/qoi.rs + qoi@0.4 spec
## Opcodes: INDEX(00) RUN(01) DIFF(10) LUMA(11+10) RGB(11111110) RGBA(11111111)

import ../color
import ../error
import ../io
import ../decoder
import ../buffer

const
  QoiOpIndex* = 0x00'u8
  QoiOpDiff* = 0x40'u8
  QoiOpLuma* = 0x80'u8
  QoiOpRun* = 0xC0'u8
  QoiOpRgb* = 0xFE'u8
  QoiOpRgba* = 0xFF'u8
  QoiMask2* = 0xC0'u8

type
  QoiHeader* = object
    width*, height*: uint32
    channels*: uint8
    colorspace*: uint8

proc parseQoiHeader*(data: openArray[uint8]): ImageResult[QoiHeader] =
  if data.len < 14:
    return err[QoiHeader](decodingError("qoi: too short"))
  if not (data[0]==uint8('q') and data[1]==uint8('o') and
      data[2]==uint8('i') and data[3]==uint8('f')):
    return err[QoiHeader](decodingError("qoi: bad magic"))
  let w = (uint32(data[4]) shl 24) or (uint32(data[5]) shl 16) or
    (uint32(data[6]) shl 8) or uint32(data[7])
  let h = (uint32(data[8]) shl 24) or (uint32(data[9]) shl 16) or
    (uint32(data[10]) shl 8) or uint32(data[11])
  if w == 0 or h == 0:
    return err[QoiHeader](decodingError("qoi: zero dimension"))
  ok(QoiHeader(width: w, height: h, channels: data[12], colorspace: data[13]))

proc decodeQoi*(data: seq[uint8]): ImageResult[RgbaImage] =
  let hr = parseQoiHeader(data)
  if not hr.ok: return err[RgbaImage](hr.err)
  let h = hr.value
  if h.channels < 3 or h.channels > 4:
    return err[RgbaImage](decodingError("qoi: bad channels"))
  let n = int(h.width) * int(h.height)
  var px = newSeq[Rgba[uint8]](n)
  var index: array[64, Rgba[uint8]]
  var pr, pg, pb: uint8 = 0
  var pa: uint8 = 255
  var pos = 14
  var i = 0
  template emit(r, g, b, a: uint8) =
    let p = Rgba[uint8](data: [r, g, b, a])
    index[((int(r)*3 + int(g)*5 + int(b)*7 + int(a)*11) mod 64)] = p
    px[i] = p
    pr = r; pg = g; pb = b; pa = a
    inc i
  while i < n:
    if pos >= data.len:
      return err[RgbaImage](decodingError("qoi: truncated"))
    let b0 = data[pos]; inc pos
    if b0 == QoiOpRgb:
      if pos + 2 >= data.len:
        return err[RgbaImage](decodingError("qoi: truncated rgb"))
      emit(data[pos], data[pos+1], data[pos+2], pa)
      pos += 3
    elif b0 == QoiOpRgba:
      if pos + 3 >= data.len:
        return err[RgbaImage](decodingError("qoi: truncated rgba"))
      emit(data[pos], data[pos+1], data[pos+2], data[pos+3])
      pos += 4
    else:
      let tag = b0 and QoiMask2
      if tag == QoiOpIndex:
        let p = index[int(b0 and 0x3F)]
        emit(p.data[0], p.data[1], p.data[2], p.data[3])
      elif tag == QoiOpDiff:
        let dr = int((b0 shr 4) and 3) - 2
        let dg = int((b0 shr 2) and 3) - 2
        let db = int(b0 and 3) - 2
        emit(uint8(int(pr) + dr), uint8(int(pg) + dg), uint8(int(pb) + db), pa)
      elif tag == QoiOpLuma:
        if pos >= data.len:
          return err[RgbaImage](decodingError("qoi: truncated luma"))
        let b1 = data[pos]; inc pos
        let dg = int(b0 and 0x3F) - 32
        let drDg = int((b1 shr 4) and 15) - 8
        let dbDg = int(b1 and 15) - 8
        emit(uint8(int(pr) + dg + drDg), uint8(int(pg) + dg),
             uint8(int(pb) + dg + dbDg), pa)
      else:
        var run = int(b0 and 0x3F) + 1
        if i + run > n:
          return err[RgbaImage](decodingError("qoi: run overflow"))
        for _ in 0..<run:
          emit(pr, pg, pb, pa)
  ok(RgbaImage(width: h.width, height: h.height, pixels: move(px)))

proc encodeQoi*(img: RgbaImage, channels = 4'u8, colorspace = 0'u8): seq[uint8] =
  result = newSeqOfCap[uint8](14 + img.pixels.len * 4 + 8)
  result.add([uint8('q'), uint8('o'), uint8('i'), uint8('f')])
  for v in [img.width, img.height]:
    result.add(uint8((v shr 24) and 0xFF))
    result.add(uint8((v shr 16) and 0xFF))
    result.add(uint8((v shr 8) and 0xFF))
    result.add(uint8(v and 0xFF))
  result.add(channels)
  result.add(colorspace)
  var index: array[64, Rgba[uint8]]
  var seen: array[64, bool]
  var pr, pg, pb: uint8 = 0
  var pa: uint8 = 255
  var run = 0
  proc flushRun(res: var seq[uint8], run: var int) =
    if run > 0:
      res.add(QoiOpRun or uint8(run - 1))
      run = 0
  for p in img.pixels:
    let (r, g, b, a) = (p.data[0], p.data[1], p.data[2], p.data[3])
    if r == pr and g == pg and b == pb and a == pa:
      inc run
      if run == 62:
        flushRun(result, run)
      continue
    flushRun(result, run)
    let idx = (int(r)*3 + int(g)*5 + int(b)*7 + int(a)*11) mod 64
    if seen[idx] and index[idx].data == [r, g, b, a]:
      result.add(uint8(idx))
    else:
      seen[idx] = true
      index[idx] = Rgba[uint8](data: [r, g, b, a])
      if a == pa:
        let vr = int(r) - int(pr)
        let vg = int(g) - int(pg)
        let vb = int(b) - int(pb)
        let vgR = vr - vg
        let vgB = vb - vg
        if vg > -3 and vg < 2 and vr > -3 and vr < 2 and vb > -3 and vb < 2:
          result.add(QoiOpDiff or (uint8(vr + 2) shl 4) or (uint8(vg + 2) shl 2) or uint8(vb + 2))
        elif vgR > -9 and vgR < 8 and vg > -33 and vg < 32 and vgB > -9 and vgB < 8:
          result.add(QoiOpLuma or uint8(vg + 32))
          result.add((uint8(vgR + 8) shl 4) or uint8(vgB + 8))
        else:
          result.add(QoiOpRgb)
          result.add([r, g, b])
      else:
        result.add(QoiOpRgba)
        result.add([r, g, b, a])
    pr = r; pg = g; pb = b; pa = a
  flushRun(result, run)
  result.add([0'u8, 0, 0, 0, 0, 0, 0, 1])
