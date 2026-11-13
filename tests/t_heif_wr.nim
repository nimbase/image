## HEIF writer/collection tests: round-trip, grid/overlay, iden,
## thumbnails, groups, metadata. Clean-room fixtures generated in-memory.
import unittest
import std/os
import image
import image/codecs/heif/heif
import image/codecs/heif/isobmff

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
  of dkRgb16:
    for px in img.rgb16.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) + uint64(px.data[2])
  of dkRgba16:
    for px in img.rgba16.pixels:
      result += uint64(px.data[0]) + uint64(px.data[1]) +
        uint64(px.data[2]) + uint64(px.data[3])
  of dkLuma16:
    for px in img.luma16.pixels: result += uint64(px.data[0])
  else: doAssert false, "unexpected kind"

proc mkMono(w, h: int, v: uint8): DynamicImage =
  var px = newSeq[Luma[uint8]](w * h)
  for i in 0 ..< px.len: px[i] = Luma[uint8](data: [v])
  DynamicImage(kind: dkLuma8, luma8: GrayImage(width: uint32(w),
    height: uint32(h), pixels: move(px)))

proc mkSolid16(w, h: int, r, g, b: uint16): DynamicImage =
  var px = newSeq[Rgb[uint16]](w * h)
  for i in 0 ..< px.len: px[i] = Rgb[uint16](data: [r, g, b])
  DynamicImage(kind: dkRgb16, rgb16: Rgb16Image(width: uint32(w),
    height: uint32(h), pixels: move(px)))

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

test "heif idat construction-1 roundtrip":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  var s = defaultItemSpec(mkSolid(8, 8, 9, 9, 9))
  s.useIdat = true
  coll.items.add(s)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.dimensions() == (8'u32, 8'u32)
  check pixelSum(dec.value) == 8*8*(9+9+9).uint64

test "heif iloc construction-2 tiling roundtrip":
  let full = mkSolid(8, 4, 10, 20, 30)
  let (fbytes, u, c, pixi, w, h) = encodeUncFrame(full)
  check fbytes.len == 8*4*3
  let half = fbytes.len div 2
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var m0 = HeifItemSpec(kind: hikMime, hidden: true, thmbTo: -1,
    irotTurns: -1, imirTopBottom: -1)
  m0.mimeType = "application/octet-stream"
  m0.metaBytes = fbytes[0 ..< half]
  var m1 = HeifItemSpec(kind: hikMime, hidden: true, thmbTo: -1,
    irotTurns: -1, imirTopBottom: -1)
  m1.mimeType = "application/octet-stream"
  m1.metaBytes = fbytes[half .. ^1]
  var virt = defaultItemSpec(full)
  virt.ilocTo = @[0, 1]
  coll.items.add(m0); coll.items.add(m1); coll.items.add(virt)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check pixelSum(dec.value) == pixelSum(full)

test "heif evc passthrough brand":
  var coll = HeifCollection(primary: 0, brand: "evc1")
  var p = HeifItemSpec(kind: hikPass, hidden: false, thmbTo: -1,
    irotTurns: -1, imirTopBottom: -1)
  p.passType = "evc1"
  p.ispeW = 64; p.ispeH = 48
  p.passBytes = @[0'u8, 1, 2, 3, 4, 5]
  p.passConfigKind = "evcC"
  p.passConfig = @[1'u8, 0, 0, 0]
  coll.items.add(p)
  let enc = writeCollection(coll)
  check enc.ok
  check (not decodeHeif(enc.value).ok)
  let items = listHeifItems(enc.value)
  check items.ok
  check items.value.len == 1
  check items.value[0].typ == "evc1"
  let ext = extractItemBytes(enc.value)
  check ext.ok
  check ext.value.len == 6

test "heif timed pict sequence unci":
  let frames = @[mkSolid(8, 8, 10, 0, 0), mkSolid(8, 8, 0, 20, 0),
    mkSolid(8, 8, 0, 0, 30)]
  let enc = writeHeifSequence(frames, hikUnc)
  check enc.ok
  let mv = heifMovieInfo(enc.value)
  check mv.ok
  check mv.value.tracks.len == 1
  check mv.value.tracks[0].coding == "unci"
  check mv.value.tracks[0].samples.len == 3
  let all = decodeHeifSequenceAll(enc.value, 0)
  check all.ok
  check all.value.len == 3
  check pixelSum(all.value[0]) == 8*8*10'u64
  check pixelSum(all.value[1]) == 8*8*20'u64
  check pixelSum(all.value[2]) == 8*8*30'u64
  let one = decodeHeifSequenceSample(enc.value, 0, 1)
  check one.ok
  check pixelSum(one.value) == 8*8*20'u64

test "heif timed pict sequence jpeg":
  let frames = @[mkSolid(8, 8, 10, 0, 0), mkSolid(8, 8, 0, 20, 0)]
  let enc = writeHeifSequence(frames, hikJpeg, 90)
  check enc.ok
  let all = decodeHeifSequenceAll(enc.value, 0)
  check all.ok
  check all.value.len == 2
  check all.value[0].dimensions() == (8'u32, 8'u32)

test "heif timed pict sequence unci v0":
  let frames = @[mkMono(8, 8, 10), mkMono(8, 8, 20), mkMono(8, 8, 30)]
  let enc = writeHeifSequence(frames, hikUnc)
  check enc.ok
  let mv = heifMovieInfo(enc.value)
  check mv.ok
  check mv.value.tracks.len == 1
  check mv.value.tracks[0].coding == "unci"
  check mv.value.tracks[0].samples.len == 3
  let all = decodeHeifSequenceAll(enc.value, 0)
  check all.ok
  check all.value.len == 3
  check all.value[0].kind == dkLuma8
  check pixelSum(all.value[0]) == 8*8*10'u64
  check pixelSum(all.value[1]) == 8*8*20'u64
  check pixelSum(all.value[2]) == 8*8*30'u64

test "heif timed pict sequence unci v0 rgb16":
  let frames = @[mkSolid16(4, 4, 1000, 2000, 3000),
    mkSolid16(4, 4, 4000, 5000, 6000)]
  let enc = writeHeifSequence(frames, hikUnc)
  check enc.ok
  let all = decodeHeifSequenceAll(enc.value, 0)
  check all.ok
  check all.value.len == 2
  check all.value[0].kind == dkRgb16
  check pixelSum(all.value[0]) == 4*4*(1000+2000+3000).uint64
  check pixelSum(all.value[1]) == 4*4*(4000+5000+6000).uint64

test "heif grid luma8 roundtrip":
  let full = mkMono(8, 4, 77)
  var left = GrayImage(width: 4, height: 4, pixels: newSeq[Luma[uint8]](16))
  var right = GrayImage(width: 4, height: 4, pixels: newSeq[Luma[uint8]](16))
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      left.pixels[y*4+x] = full.luma8.pixels[y*8+x]
      right.pixels[y*4+x] = full.luma8.pixels[y*8+4+x]
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var s0 = defaultItemSpec(DynamicImage(kind: dkLuma8, luma8: left))
  s0.hidden = true
  var s1 = defaultItemSpec(DynamicImage(kind: dkLuma8, luma8: right))
  s1.hidden = true
  var g = HeifItemSpec(kind: hikGrid, gridTiles: @[0, 1], gridRows: 1,
    gridCols: 2, gridOutW: 8, gridOutH: 4, thmbTo: -1, irotTurns: -1,
    imirTopBottom: -1)
  coll.items.add(s0); coll.items.add(s1); coll.items.add(g)
  coll.items[2].dimgTo = @[0, 1]
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.kind == dkLuma8
  check pixelSum(dec.value) == pixelSum(full)

test "heif grid rgb16 roundtrip":
  let full = mkSolid16(8, 4, 1000, 2000, 3000)
  var left = Rgb16Image(width: 4, height: 4, pixels: newSeq[Rgb[uint16]](16))
  var right = Rgb16Image(width: 4, height: 4, pixels: newSeq[Rgb[uint16]](16))
  for y in 0 ..< 4:
    for x in 0 ..< 4:
      left.pixels[y*4+x] = full.rgb16.pixels[y*8+x]
      right.pixels[y*4+x] = full.rgb16.pixels[y*8+4+x]
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var s0 = defaultItemSpec(DynamicImage(kind: dkRgb16, rgb16: left))
  s0.hidden = true
  var s1 = defaultItemSpec(DynamicImage(kind: dkRgb16, rgb16: right))
  s1.hidden = true
  var g = HeifItemSpec(kind: hikGrid, gridTiles: @[0, 1], gridRows: 1,
    gridCols: 2, gridOutW: 8, gridOutH: 4, thmbTo: -1, irotTurns: -1,
    imirTopBottom: -1)
  coll.items.add(s0); coll.items.add(s1); coll.items.add(g)
  coll.items[2].dimgTo = @[0, 1]
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb16
  check pixelSum(dec.value) == pixelSum(full)

test "heif overlay rgba8 roundtrip":
  var bgpx = newSeq[Rgba[uint8]](8*8)
  for i in 0 ..< bgpx.len: bgpx[i] = Rgba[uint8](data: [255'u8, 0, 0, 255])
  var fgpx = newSeq[Rgba[uint8]](4*4)
  for i in 0 ..< fgpx.len: fgpx[i] = Rgba[uint8](data: [0'u8, 255, 0, 255])
  let bg = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 8, height: 8,
    pixels: move(bgpx)))
  let fg = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 4, height: 4,
    pixels: move(fgpx)))
  var coll = HeifCollection(primary: 2, brand: "mif1")
  var s0 = defaultItemSpec(bg); s0.hidden = true
  var s1 = defaultItemSpec(fg); s1.hidden = true
  var ov = HeifItemSpec(kind: hikOverlay, overlayInputs: @[0, 1],
    overlayOffs: @[(0, 0), (2, 2)], overlayOutW: 8, overlayOutH: 8,
    thmbTo: -1, irotTurns: -1, imirTopBottom: -1)
  coll.items.add(s0); coll.items.add(s1); coll.items.add(ov)
  coll.items[2].dimgTo = @[0, 1]
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.kind == dkRgba8
  check dec.value.dimensions() == (8'u32, 8'u32)
  # corner stays red, center is green
  check dec.value.rgba8.pixels[0].data == [255'u8, 0, 0, 255]
  check dec.value.rgba8.pixels[3*8+3].data == [0'u8, 255, 0, 255]

test "heif derivation validation rejects bad refs":
  var badIden = HeifCollection(primary: 1, brand: "mif1")
  badIden.items.add(defaultItemSpec(mkSolid(4, 4, 1, 2, 3)))
  badIden.items.add(HeifItemSpec(kind: hikIden, ispeW: 4, ispeH: 4,
    thmbTo: -1, irotTurns: -1, imirTopBottom: -1, dimgTo: @[]))
  check (not writeCollection(badIden).ok)
  var badGrid = HeifCollection(primary: 2, brand: "mif1")
  badGrid.items.add(defaultItemSpec(mkSolid(4, 4, 1, 2, 3)))
  badGrid.items.add(defaultItemSpec(mkSolid(4, 4, 1, 2, 3)))
  badGrid.items.add(HeifItemSpec(kind: hikGrid, gridTiles: @[0], gridRows: 1,
    gridCols: 2, gridOutW: 8, gridOutH: 4, thmbTo: -1, irotTurns: -1,
    imirTopBottom: -1, dimgTo: @[0]))
  check (not writeCollection(badGrid).ok)

test "heif tiled uncompressed still roundtrip":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  var s = defaultItemSpec(mkSolid(8, 8, 10, 20, 30))
  s.tileCols = 2; s.tileRows = 2
  coll.items.add(s)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (8'u32, 8'u32)
  check pixelSum(dec.value) == 8*8*(10+20+30).uint64

test "heif tiled uncompressed uneven tiles roundtrip":
  # 7x5 with 2x2 tiles exercises right/bottom edge clipping.
  var coll = HeifCollection(primary: 0, brand: "mif1")
  var s = defaultItemSpec(mkSolid(7, 5, 1, 2, 3))
  s.tileCols = 2; s.tileRows = 2
  coll.items.add(s)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.dimensions() == (7'u32, 5'u32)
  check pixelSum(dec.value) == 7*5*(1+2+3).uint64

test "heif tiled uncompressed luma roundtrip":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  var s = defaultItemSpec(mkMono(8, 4, 77))
  s.tileCols = 2; s.tileRows = 1
  coll.items.add(s)
  let enc = writeCollection(coll)
  check enc.ok
  let dec = decodeHeif(enc.value)
  check dec.ok
  check dec.value.kind == dkLuma8
  check pixelSum(dec.value) == 8*4*77'u64

test "heif unknown tile geometry stays unsupported":
  var coll = HeifCollection(primary: 0, brand: "mif1")
  var s = defaultItemSpec(mkSolid(8, 8, 10, 20, 30))
  s.tileCols = 2; s.tileRows = 2
  coll.items.add(s)
  let enc = writeCollection(coll)
  check enc.ok
  var bad = enc.value
  var idx = -1
  for i in 0 ..< bad.len - 1:
    if bad[i] == uint8('T') and bad[i+1] == uint8('L'):
      idx = i
      break
  check idx >= 0
  bad[idx] = uint8('X') # break the "TL" magic; tail stays nonzero
  let dec = decodeHeif(bad)
  check (not dec.ok)
  check dec.err.kind == ekUnsupported

test "heif tiled writer rejects bad grids":
  var c0 = HeifCollection(primary: 0, brand: "mif1")
  var s0 = defaultItemSpec(mkSolid(8, 8, 1, 2, 3))
  s0.tileCols = 0; s0.tileRows = 2 # half-specified grid
  c0.items.add(s0)
  check (not writeCollection(c0).ok)
  var c1 = HeifCollection(primary: 0, brand: "mif1")
  var s1 = defaultItemSpec(mkSolid(8, 8, 1, 2, 3))
  s1.tileCols = 16; s1.tileRows = 1 # more columns than pixels
  c1.items.add(s1)
  check (not writeCollection(c1).ok)
  var c2 = HeifCollection(primary: 0, brand: "mif1")
  var s2 = defaultItemSpec(mkSolid(8, 8, 1, 2, 3))
  s2.kind = hikJpeg
  s2.tileCols = 2; s2.tileRows = 2 # tiling needs uncompressed
  c2.items.add(s2)
  check (not writeCollection(c2).ok)

test "heif timed pict sequence tiled unci":
  let frames = @[mkSolid(8, 8, 10, 0, 0), mkSolid(8, 8, 0, 20, 0)]
  let enc = writeHeifSequence(frames, hikUnc, 90, 1, 1, 2, 2)
  check enc.ok
  let all = decodeHeifSequenceAll(enc.value, 0)
  check all.ok
  check all.value.len == 2
  check pixelSum(all.value[0]) == 8*8*10'u64
  check pixelSum(all.value[1]) == 8*8*20'u64

proc buildFragmentedSeq(samples: seq[seq[uint8]], entry: seq[uint8],
    trackId: uint32, moofTrack = 0'u32): seq[uint8] =
  ## Minimal fragmented file: ftyp + moov (empty sample tables, valid
  ## descriptions) + moof (tfhd/trun) + mdat. Clean-room test helper.
  ## moofTrack, when nonzero, overrides the tfhd reference (to test the
  ## unknown-track error path).
  let ftyp = buildFtyp("msf1", @["msf1", "mif1", "miaf", "1pic", "unci"])
  let stbl = makeBox("stbl", buildStsd(@[entry]) & buildStts(0, 1) &
    buildStsc(0) & buildStsz(@[]) & buildStco(@[]))
  let minf = makeBox("minf", buildVmhd() & buildDinf() & stbl)
  let mdia = makeBox("mdia", buildMdhd(1, 2) & buildHdlr() & minf)
  let trak = makeBox("trak", buildTkhd(trackId, 2, 8, 8) & mdia)
  let moov = makeBox("moov", buildMvhd(1, 2) & trak)
  var sizes: seq[int] = @[]
  for b in samples: sizes.add(b.len)
  proc moofWith(base: uint64): seq[uint8] =
    let refId = if moofTrack != 0: moofTrack else: trackId
    var tfhd: seq[uint8] = @[]
    tfhd.putFullHeader(0, 1) # base-data-offset-present
    tfhd.putU32BE(refId)
    tfhd.putU64BE(base)
    var trun: seq[uint8] = @[]
    trun.putFullHeader(0, 0x301) # data-offset + duration + size
    trun.putU32BE(0) # data_offset (base already points at first sample)
    trun.putU32BE(uint32(samples.len))
    for b in samples:
      trun.putU32BE(1) # duration
      trun.putU32BE(uint32(b.len))
    var mfhdInner: seq[uint8] = @[]
    mfhdInner.putU32BE(1)
    makeBox("moof", makeFullBox("mfhd", 0, 0, mfhdInner) &
      makeBox("traf", makeBox("tfhd", tfhd) & makeBox("trun", trun)))
  # Base points at the mdat payload; moof size is offset-independent.
  let dummy = moofWith(0)
  let base = uint64(ftyp.len + moov.len + dummy.len + 8)
  let moof = moofWith(base)
  doAssert moof.len == dummy.len
  var mdatPayload: seq[uint8] = @[]
  for b in samples: mdatPayload.putBytes(b)
  ftyp & moov & moof & makeBox("mdat", mdatPayload)

test "heif fragmented moof sequence decodes":
  let f0 = mkSolid(8, 8, 10, 0, 0)
  let f1 = mkSolid(8, 8, 0, 20, 0)
  let (b0, u0, c0, p0, _, _) = encodeUncFrame(f0)
  let (b1, u1, c1, p1, _, _) = encodeUncFrame(f1)
  check makeBox("uncC", u0) == makeBox("uncC", u1)
  let entry = buildVisualEntry("unci", 8, 8, @[makeBox("uncC", u0)])
  let raw = buildFragmentedSeq(@[b0, b1], entry, 1)
  let mv = heifMovieInfo(raw)
  check mv.ok
  check mv.value.hasMoof
  check mv.value.tracks.len == 1
  check mv.value.tracks[0].samples.len == 2
  check mv.value.tracks[0].samples[0].duration == 1
  let all = decodeHeifSequenceAll(raw, 0)
  check all.ok
  check all.value.len == 2
  check pixelSum(all.value[0]) == 8*8*10'u64
  check pixelSum(all.value[1]) == 8*8*20'u64
  let one = decodeHeifSequenceSample(raw, 0, 1)
  check one.ok
  check pixelSum(one.value) == 8*8*20'u64

test "heif fragmented moof truncated and bad track fail cleanly":
  let f0 = mkSolid(8, 8, 10, 0, 0)
  let (b0, u0, c0, p0, _, _) = encodeUncFrame(f0)
  let entry = buildVisualEntry("unci", 8, 8, @[makeBox("uncC", u0)])
  let raw = buildFragmentedSeq(@[b0], entry, 1)
  check decodeHeifSequenceAll(raw[0 ..< raw.len - 1], 0).ok == false
  check heifMovieInfo(raw[0 ..< raw.len div 2]).ok == false
  let badTrack = buildFragmentedSeq(@[b0], entry, 1, 99)
  check heifMovieInfo(badTrack).ok == false
