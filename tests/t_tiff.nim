import unittest
import image
import image/codecs/tiff

test "tiff rgb8 round-trip":
  var px = @[Rgb[uint8](data: [255'u8, 0, 0]), Rgb[uint8](data: [0'u8, 255, 0]),
             Rgb[uint8](data: [0'u8, 0, 255]), Rgb[uint8](data: [255'u8, 255, 255])]
  let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 2, height: 2, pixels: px))
  let enc = encodeTiff(img)
  check enc.ok
  check enc.value[0] == uint8('I')
  let dec = decodeTiff(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.rgb8.pixels == px

test "tiff gray8 + rgba8 + rgb16":
  var g = @[Luma[uint8](data: [0'u8]), Luma[uint8](data: [200'u8])]
  let gi = DynamicImage(kind: dkLuma8, luma8: GrayImage(width: 2, height: 1, pixels: g))
  let gd = decodeTiff(encodeTiff(gi).value)
  check gd.ok and gd.value.kind == dkLuma8
  check gd.value.luma8.pixels == g
  var a = @[Rgba[uint8](data: [1'u8, 2, 3, 4]), Rgba[uint8](data: [5'u8, 6, 7, 8])]
  let ai = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 2, height: 1, pixels: a))
  let ad = decodeTiff(encodeTiff(ai).value)
  check ad.ok and ad.value.kind == dkRgba8
  check ad.value.rgba8.pixels == a
  var s = @[Rgb[uint16](data: [65535'u16, 0, 0]), Rgb[uint16](data: [0'u16, 1, 2])]
  let si = DynamicImage(kind: dkRgb16, rgb16: Rgb16Image(width: 2, height: 1, pixels: s))
  let sd = decodeTiff(encodeTiff(si).value)
  check sd.ok and sd.value.kind == dkRgb16
  check sd.value.rgb16.pixels == s

test "tiff bad signature":
  check decodeTiff(@[0'u8, 1, 2, 3, 4, 5, 6, 7]).ok == false

test "tiff big-endian manual gray":
  # BE header, 1x1 gray8 value 200, single strip
  var d = @[uint8('M'), uint8('M'), 0, 42, 0, 0, 0, 8]
  d.add([0'u8, 9]) # 9 entries
  template e16(v: uint16) =
    d.add([uint8((v shr 8) and 0xFF), uint8(v and 0xFF)])
  template e32(v: uint32) =
    d.add([uint8((v shr 24) and 0xFF), uint8((v shr 16) and 0xFF),
      uint8((v shr 8) and 0xFF), uint8(v and 0xFF)])
  template ent(tag, typ: uint16, cnt, val: uint32) =
    e16(tag); e16(typ); e32(cnt)
    # TIFF: SHORT values are left-justified in the value field for big-endian
    if typ == 3: e32(val shl 16) else: e32(val)
  let dataOff = 8 + 2 + 9*12 + 4
  ent(256, 4, 1, 1); ent(257, 4, 1, 1); ent(258, 3, 1, 8)
  ent(259, 3, 1, 1); ent(262, 3, 1, 1); ent(273, 4, 1, uint32(dataOff))
  ent(277, 3, 1, 1); ent(278, 4, 1, 1); ent(279, 4, 1, 1)
  d.add([0'u8, 0, 0, 0]) # next IFD
  d.add([200'u8])
  let dec = decodeTiff(d)
  check dec.ok
  check dec.value.kind == dkLuma8
  check dec.value.luma8.pixels[0].data == [200'u8]

test "tiff packbits":
  # LE 2x1 gray8 [10, 10] via PackBits literal run: count byte 1, two bytes
  var d = @[uint8('I'), uint8('I'), 42, 0, 8, 0, 0, 0]
  d.add([9'u8, 0])
  template e16(v: uint16) =
    d.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF)])
  template e32(v: uint32) =
    d.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF),
      uint8((v shr 16) and 0xFF), uint8((v shr 24) and 0xFF)])
  template ent(tag, typ: uint16, cnt, val: uint32) =
    e16(tag); e16(typ); e32(cnt); e32(val)
  let dataOff = 8 + 2 + 9*12 + 4
  ent(256, 4, 1, 2); ent(257, 4, 1, 1); ent(258, 3, 1, 8)
  ent(259, 3, 1, 32773); ent(262, 3, 1, 1); ent(273, 4, 1, uint32(dataOff))
  ent(277, 3, 1, 1); ent(278, 4, 1, 1); ent(279, 4, 1, 3)
  e32(0)
  d.add([1'u8, 10, 10])
  let dec = decodeTiff(d)
  check dec.ok
  check dec.value.luma8.pixels[0].data == [10'u8]
  check dec.value.luma8.pixels[1].data == [10'u8]

test "tiff tiled 1-bit decodes bit-exact":
  # Hand-built LE classic TIFF: BlackIsZero 1-bit with 8x8 tiles over a
  # 10x10 image (exercises full + partial edge tiles). Guards the packed
  # row-bit placement (byteIdx must not double-count the row offset) and
  # the pooled sub-byte row scratch.
  proc buildTiled1(w, h, tw, th: int,
      bitAt: proc(x, y: int): bool): seq[uint8] =
    var d = @[uint8('I'), uint8('I'), 42, 0, 8, 0, 0, 0]
    template e16(v: uint16) =
      d.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF)])
    template e32(v: uint32) =
      d.add([uint8(v and 0xFF), uint8((v shr 8) and 0xFF),
        uint8((v shr 16) and 0xFF), uint8((v shr 24) and 0xFF)])
    template ent(tag, typ: uint16, cnt, val: uint32) =
      e16(tag); e16(typ); e32(cnt); e32(val)
    let across = (w + tw - 1) div tw
    let down = (h + th - 1) div th
    let n = across * down
    var tiles = newSeq[uint8]()
    var offs = newSeq[uint32](n)
    var cnts = newSeq[uint32](n)
    for ty in 0..<down:
      for tx in 0..<across:
        let cw = min(tw, w - tx * tw); let chh = min(th, h - ty * th)
        let rb = (cw + 7) div 8
        offs[ty * across + tx] = uint32(tiles.len)
        for r in 0..<chh:
          var row = newSeq[uint8](rb)
          for x in 0..<cw:
            if bitAt(tx * tw + x, ty * th + r):
              row[x div 8] = row[x div 8] or uint8(1 shl (7 - (x mod 8)))
          tiles.add(row)
        cnts[ty * across + tx] = uint32(rb * chh)
    # header(8) + count(2) + 10 entries(120) + next(4); then offset arrays.
    let arrOff = 8 + 2 + 10 * 12 + 4
    let tileOff = arrOff + n * 4 * 2
    for i in 0..<n: offs[i] += uint32(tileOff)
    e16(uint16(10))
    ent(256, 3, 1, uint32(w)); ent(257, 3, 1, uint32(h))
    ent(258, 3, 1, 1); ent(259, 3, 1, 1); ent(262, 3, 1, 1)
    ent(322, 3, 1, uint32(tw)); ent(323, 3, 1, uint32(th))
    ent(324, 4, uint32(n), uint32(arrOff))
    ent(325, 4, uint32(n), uint32(arrOff + n * 4))
    ent(277, 3, 1, 1)
    e32(0)
    for o in offs: e32(o)
    for c in cnts: e32(c)
    d.add(tiles)
    d
  let img = buildTiled1(10, 10, 8, 8, proc(x, y: int): bool = (x + y) mod 2 == 0)
  let tdec = decodeTiff(img)
  check tdec.ok
  check tdec.value.dimensions() == (10'u32, 10'u32)
  for y in 0..<10:
    for x in 0..<10:
      let want = if (x + y) mod 2 == 0: 255'u8 else: 0'u8
      check tdec.value.luma8.pixels[y * 10 + x].data == [want]
