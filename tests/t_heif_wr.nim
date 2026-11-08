## HEIF writer/collection tests: round-trip, grid/overlay, iden,
## thumbnails, groups, metadata. Clean-room fixtures generated in-memory.
import unittest
import std/os
import image
import image/codecs/heif/heif

let fixturesDir = currentSourcePath().parentDir() / "fixtures" / "heif"

proc readRaw(p: string): seq[uint8] =
  var f = open(p, fmRead)
  result = newSeq[uint8](getFileSize(f))
  discard readBytes(f, result, 0, result.len)
  close(f)

proc pixelSum(img: DynamicImage): uint64 =
  case img.kind
  of dkRgb8:
    for px in img.rgb8.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
  of dkRgba8:
    for px in img.rgba8.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) +
        uint64(px.data[2]) + uint64(px.data[3])
  of dkLuma8:
    for px in img.luma8.pixels: result += uint64(px.data[0])
  else: doAssert false, "unexpected kind"

proc mkSolid(w, h: int, r, g, b: uint8): DynamicImage =
  var px = newSeq[Rgb[uint8]](w * h)
  for i in 0 ..< px.len: px[i] = Rgb[uint8](data: [r, g, b])
  DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: uint32(w),
    height: uint32(h), pixels: move(px)))

test "heif writer unci roundtrip":
  let dec = decodeHeif(readRaw(fixturesDir / "unc-rgb-64x48.heif"))
  check dec.ok
  let enc = encodeHeif(dec.value)
  check enc.ok
  let rt = decodeHeif(enc.value)
  check rt.ok
  check rt.value.dimensions() == dec.value.dimensions()
  check pixelSum(rt.value) == pixelSum(dec.value)

test "heif writer jpeg roundtrip":
  let dec = decodeHeif(readRaw(fixturesDir / "unc-rgb-64x48.heif"))
  check dec.ok
  let enc = encodeHeifJpeg(dec.value, 90)
  check enc.ok
  let rt = decodeHeif(enc.value)
  check rt.ok
  check rt.value.dimensions() == (64'u32, 48'u32)

test "heif grid roundtrip":
  let full = decodeHeif(readRaw(fixturesDir / "unc-rgb-64x48.heif"))
  check full.ok
  let w = 64; let h = 48
  var left = RgbImage(width: 32, height: 48, pixels: newSeq[Rgb[uint8]](32*48))
  var right = RgbImage(width: 32, height: 48, pixels: newSeq[Rgb[uint8]](32*48))
  for y in 0 ..< h:
    for x in 0 ..< 32:
      left.pixels[y*32+x] = full.value.rgb8.pixels[y*w+x]
      right.pixels[y*32+x] = full.value.rgb8.pixels[y*w+32+x]
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var s0 = defaultItemSpec(DynamicImage(kind: dkRgb8, rgb8: left))
  s0.hidden = true
  var s1 = defaultItemSpec(DynamicImage(kind: dkRgb8, rgb8: right))
  s1.hidden = true
  var g = HeifItemSpec(kind: hikGrid, gridTiles: @[0, 1], gridRows: 1,
    gridCols: 2, gridOutW: 64, gridOutH: 48, thmbTo: -1, irotTurns: -1,
    imirTopBottom: -1)
  coll.items.add(s0); coll.items.add(s1); coll.items.add(g)
  coll.items[2].dimgTo = @[0, 1]
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check pixelSum(dec.value) == pixelSum(full.value)

test "heif overlay roundtrip":
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var s0 = defaultItemSpec(mkSolid(64, 48, 255, 0, 0)); s0.hidden = true
  var s1 = defaultItemSpec(mkSolid(16, 16, 0, 255, 0)); s1.hidden = true
  var ov = HeifItemSpec(kind: hikOverlay, overlayInputs: @[0, 1],
    overlayOffs: @[(0, 0), (8, 8)], overlayOutW: 64, overlayOutH: 48,
    thmbTo: -1, irotTurns: -1, imirTopBottom: -1)
  coll.items.add(s0); coll.items.add(s1); coll.items.add(ov)
  coll.items[2].dimgTo = @[0, 1]
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.dimensions() == (64'u32, 48'u32)
  check pixelSum(dec.value) == 783360'u64

test "heif iden irot":
  var coll = HeifCollection(primary: 1, brand: "mif1")
  var t0 = defaultItemSpec(mkSolid(4, 2, 10, 20, 30)); t0.hidden = true
  var iden = HeifItemSpec(kind: hikIden, ispeW: 2, ispeH: 4, thmbTo: -1,
    irotTurns: 1, imirTopBottom: -1, dimgTo: @[0])
  coll.items.add(t0); coll.items.add(iden)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.dimensions() == (2'u32, 4'u32)

test "heif thumbnail and altr group":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  coll.items.add(defaultItemSpec(mkSolid(64, 48, 1, 2, 3)))
  var th = defaultItemSpec(mkSolid(8, 8, 1, 2, 3))
  th.thmbTo = 0
  coll.items.add(th)
  coll.groups.add(EntityGroup(grouping: "altr", groupId: 1,
    entityIds: @[1'u32, 2'u32]))
  let enc = writeCollection(coll)
  check enc.ok
  check decodeHeif(enc.value).ok
  let allItems = decodeHeifAll(enc.value)
  check allItems.ok
  check allItems.value.len == 2
  let gr = heifGroups(enc.value)
  check gr.ok
  check gr.value.len == 1
  check listHeifItems(enc.value).value.len == 2

test "heif exif and xmp roundtrip":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  coll.items.add(defaultItemSpec(mkSolid(8, 8, 9, 9, 9)))
  var ex = HeifItemSpec(kind: hikExif, hidden: false, thmbTo: -1,
    irotTurns: -1, imirTopBottom: -1)
  ex.metaBytes = @[0'u8, 0, 0, 0, 0x49'u8, 0x49, 0x2A, 0x00]
  ex.cdscTo = @[0]
  var xm = HeifItemSpec(kind: hikMime, hidden: false, thmbTo: -1,
    irotTurns: -1, imirTopBottom: -1)
  xm.mimeType = "application/rdf+xml"
  xm.metaBytes = @[uint8('<'), uint8('x'), uint8('/'), uint8('>')]
  xm.cdscTo = @[0]
  coll.items.add(ex); coll.items.add(xm)
  let enc = writeCollection(coll)
  check enc.ok
  check decodeHeif(enc.value).ok
  let md = heifMetadata(enc.value)
  check md.ok
  check md.value.len == 2
