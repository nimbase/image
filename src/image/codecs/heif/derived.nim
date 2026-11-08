## Derived image items: grid and overlay (clean-room, MIT).
## Parses item payloads for 'grid' and 'iovl' and composites
## DynamicImages. Only 8-bit RGB/RGBA/Luma paths are rendered;
## 16-bit follows the same tiling logic.
import ./isobmff
import ../..//error
import ../../buffer
import ../../dynamic
import ../../color

type
  GridInfo* = object
    rows*, cols*: int
    outW*, outH*: int
  OverlayInfo* = object
    outW*, outH*: int
    offX*, offY*: seq[int]
    fill*: array[4, uint16]

proc parseGrid*(payload: seq[uint8]): GridInfo =
  if payload.len < 8: raise heifErr("heif: truncated grid")
  if payload[0] != 0: raise heifErr("heif: bad grid version")
  let wide = (payload[1] and 1) != 0
  let rows = int(payload[2]) + 1
  let cols = int(payload[3]) + 1
  var w, h: int
  if not wide:
    if payload.len < 8: raise heifErr("heif: truncated grid")
    w = (int(payload[4]) shl 8) or int(payload[5])
    h = (int(payload[6]) shl 8) or int(payload[7])
  else:
    if payload.len < 12: raise heifErr("heif: truncated grid")
    w = (int(payload[4]) shl 24) or (int(payload[5]) shl 16) or
      (int(payload[6]) shl 8) or int(payload[7])
    h = (int(payload[8]) shl 24) or (int(payload[9]) shl 16) or
      (int(payload[10]) shl 8) or int(payload[11])
  if rows <= 0 or cols <= 0 or rows * cols > 256: raise heifErr("heif: bad grid size")
  if w <= 0 or h <= 0 or w > 16384 or h > 16384: raise heifErr("heif: bad grid output")
  GridInfo(rows: rows, cols: cols, outW: w, outH: h)

proc parseOverlay*(payload: seq[uint8], refCount: int): OverlayInfo =
  if payload.len < 12: raise heifErr("heif: truncated iovl")
  if payload[0] != 0: raise heifErr("heif: bad iovl version")
  let wide = (payload[1] and 1) != 0
  var fill: array[4, uint16]
  for j in 0 ..< 4:
    fill[j] = (uint16(payload[2 + 2*j]) shl 8) or uint16(payload[3 + 2*j])
  let flen = if wide: 4 else: 2
  proc rd(off: int, n: int): int =
    if n == 2:
      if payload.len < off + 2: raise heifErr("heif: truncated iovl")
      (int(payload[off]) shl 8) or int(payload[off+1])
    else:
      if payload.len < off + 4: raise heifErr("heif: truncated iovl")
      (int(payload[off]) shl 24) or (int(payload[off+1]) shl 16) or
        (int(payload[off+2]) shl 8) or int(payload[off+3])
  proc rds(off: int, n: int): int =
    let u = rd(off, n)
    if n == 2:
      if u >= 0x8000: u - 0x10000 else: u
    else:
      if u >= 0x80000000: u - 0x100000000 else: u
  let base = 10
  let ow = rd(base, flen)
  let oh = rd(base + flen, flen)
  if ow <= 0 or oh <= 0 or ow > 16384 or oh > 16384:
    raise heifErr("heif: bad overlay canvas")
  var ox: seq[int] = @[]
  var oy: seq[int] = @[]
  var o = base + 2 * flen
  for i in 0 ..< refCount:
    ox.add(rds(o, flen)); oy.add(rds(o + flen, flen)); o += 2 * flen
  OverlayInfo(outW: ow, outH: oh, offX: ox, offY: oy, fill: fill)

proc buildGrid*(rows, cols, outW, outH: int): seq[uint8] =
  let wide = outW > 65535 or outH > 65535
  result = @[0'u8, if wide: 1'u8 else: 0'u8,
    uint8(rows - 1), uint8(cols - 1)]
  if not wide:
    result.add(uint8(outW shr 8)); result.add(uint8(outW and 0xFF))
    result.add(uint8(outH shr 8)); result.add(uint8(outH and 0xFF))
  else:
    for v in [outW, outH]:
      result.add(uint8(v shr 24)); result.add(uint8((v shr 16) and 0xFF))
      result.add(uint8((v shr 8) and 0xFF)); result.add(uint8(v and 0xFF))

proc buildOverlay*(outW, outH: int, offs: seq[tuple[x, y: int]]): seq[uint8] =
  let wide = outW > 65535 or outH > 65535
  result = @[0'u8, if wide: 1'u8 else: 0'u8,
    0'u8, 0'u8, 0'u8, 0'u8, 0'u8, 0xFF'u8, 0xFF'u8, 0xFF'u8]
  let n = if wide: 4 else: 2
  template pu(v: int) =
    if n == 2:
      result.add(uint8((v shr 8) and 0xFF)); result.add(uint8(v and 0xFF))
    else:
      result.add(uint8((v shr 24) and 0xFF))
      result.add(uint8((v shr 16) and 0xFF))
      result.add(uint8((v shr 8) and 0xFF))
      result.add(uint8(v and 0xFF))
  pu(outW); pu(outH)
  for o in offs:
    let xu = if o.x < 0: (if n == 2: 0x10000 + o.x else: 0x100000000 + o.x) else: o.x
    let yu = if o.y < 0: (if n == 2: 0x10000 + o.y else: 0x100000000 + o.y) else: o.y
    pu(xu); pu(yu)

# --- Compositing (8-bit fast paths; 16-bit mirrors) ---

proc compositeGridRgb8*(tiles: seq[RgbImage], g: GridInfo): RgbImage =
  doAssert tiles.len == g.rows * g.cols
  let tw = int(tiles[0].width)
  let th = int(tiles[0].height)
  for t in tiles:
    doAssert int(t.width) == tw and int(t.height) == th
  var px = newSeq[Rgb[uint8]](g.outW * g.outH)
  for r in 0 ..< g.rows:
    for c in 0 ..< g.cols:
      let t = tiles[r * g.cols + c]
      for y in 0 ..< th:
        let dy = r * th + y
        if dy >= g.outH: break
        for x in 0 ..< tw:
          let dx = c * tw + x
          if dx >= g.outW: break
          px[dy * g.outW + dx] = t.pixels[y * tw + x]
  RgbImage(width: uint32(g.outW), height: uint32(g.outH), pixels: move(px))

proc compositeGridRgba8*(tiles: seq[RgbaImage], g: GridInfo): RgbaImage =
  doAssert tiles.len == g.rows * g.cols
  let tw = int(tiles[0].width)
  let th = int(tiles[0].height)
  var px = newSeq[Rgba[uint8]](g.outW * g.outH)
  for r in 0 ..< g.rows:
    for c in 0 ..< g.cols:
      let t = tiles[r * g.cols + c]
      for y in 0 ..< th:
        let dy = r * th + y
        if dy >= g.outH: break
        for x in 0 ..< tw:
          let dx = c * tw + x
          if dx >= g.outW: break
          px[dy * g.outW + dx] = t.pixels[y * tw + x]
  RgbaImage(width: uint32(g.outW), height: uint32(g.outH), pixels: move(px))

proc compositeOverlayRgb8*(layers: seq[RgbImage], o: OverlayInfo): RgbImage =
  var px = newSeq[Rgb[uint8]](o.outW * o.outH)
  let fr = uint8(o.fill[0] shr 8)
  let fg = uint8(o.fill[1] shr 8)
  let fb = uint8(o.fill[2] shr 8)
  for i in 0 ..< px.len: px[i] = Rgb[uint8](data: [fr, fg, fb])
  for li in 0 ..< layers.len:
    let t = layers[li]
    let ox = o.offX[li]
    let oy = o.offY[li]
    for y in 0 ..< int(t.height):
      let dy = oy + y
      if dy < 0 or dy >= o.outH: continue
      for x in 0 ..< int(t.width):
        let dx = ox + x
        if dx < 0 or dx >= o.outW: continue
        px[dy * o.outW + dx] = t.pixels[y * int(t.width) + x]
  RgbImage(width: uint32(o.outW), height: uint32(o.outH), pixels: move(px))
