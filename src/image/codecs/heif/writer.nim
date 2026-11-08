## HEIF writer (clean-room, MIT).
## Builds still-image files: ftyp + meta + mdat.
## Supports single stills, collections (thumbnails, aux, iden),
## grid/overlay derived items and entity groups. No copied
## structures from other implementations; layout derived from
## observed files and the box framing rules.
import ./isobmff
import ./props
import ./derived
import ./groups
import ../../error
import ../../buffer
import ../../dynamic
import ../../color
import ../jpgenc

type
  HeifItemKind* = enum
    hikUnc
    hikJpeg
    hikGrid
    hikOverlay
    hikIden
    hikExif
    hikMime
    hikUri

  HeifItemSpec* = object
    kind*: HeifItemKind
    image*: DynamicImage ## for hikUnc / hikJpeg
    jpegQuality*: int ## for hikJpeg
    gridTiles*: seq[int] ## item indexes (0-based into collection) for grid
    gridRows*, gridCols*: int
    gridOutW*, gridOutH*: int
    overlayInputs*: seq[int]
    overlayOffs*: seq[tuple[x, y: int]]
    overlayOutW*, overlayOutH*: int
    hidden*: bool
    ispeW*, ispeH*: uint32 ## explicit extents for derived/iden
    auxType*: string ## "" = not aux
    thmbTo*: int ## -1 = none, else collection index of master
    dimgTo*: seq[int] ## for iden/grid/overlay
    cdscTo*: seq[int] ## metadata describes these items
    mimeType*: string ## for hikMime
    uriType*: string ## for hikUri
    metaBytes*: seq[uint8] ## raw payload for Exif/mime/uri
    irotTurns*: int ## -1 = none
    imirTopBottom*: int ## -1 none, 0 top-bottom, 1 left-right
    clapRect*: tuple[has: bool, w, h: uint32, x, y: int32]

  HeifCollection* = object
    items*: seq[HeifItemSpec]
    primary*: int
    groups*: seq[EntityGroup]
    brand*: string ## "mif1" default, "heic" for HEVC-branded (passthrough only)

proc defaultItemSpec*(img: DynamicImage): HeifItemSpec =
  HeifItemSpec(kind: hikUnc, image: img, jpegQuality: 90,
    thmbTo: -1, irotTurns: -1, imirTopBottom: -1)

# --- Frame encoding (unc, reverse of unc.nim pixel path) ---

proc encodeUncFrame*(img: DynamicImage): tuple[bytes: seq[uint8],
    uncC: seq[uint8], cmpd: seq[uint8], pixi: seq[int], w, h: uint32] =
  let (w, h) = img.dimensions()
  case img.kind
  of dkRgb8:
    var outb = newSeq[uint8](int(w) * int(h) * 3)
    var p = 0
    for px in img.rgb8.pixels:
      outb[p] = px.data[0]; outb[p+1] = px.data[1]; outb[p+2] = px.data[2]
      p += 3
    (outb, buildUncCV1("rgb3"), @[], @[8, 8, 8], w, h)
  of dkRgba8:
    var outb = newSeq[uint8](int(w) * int(h) * 4)
    var p = 0
    for px in img.rgba8.pixels:
      outb[p] = px.data[0]; outb[p+1] = px.data[1]
      outb[p+2] = px.data[2]; outb[p+3] = px.data[3]
      p += 4
    (outb, buildUncCV1("rgba"), @[], @[8, 8, 8, 8], w, h)
  of dkLuma8:
    var outb = newSeq[uint8](int(w) * int(h))
    for i, px in img.luma8.pixels: outb[i] = px.data[0]
    (outb, buildUncCV0(8, 0, 0, [1]), buildCmpd([1]), @[8], w, h)
  of dkRgb16:
    var outb = newSeq[uint8](int(w) * int(h) * 6)
    var p = 0
    for px in img.rgb16.pixels:
      for c in 0 ..< 3:
        outb[p] = uint8(px.data[c] shr 8); outb[p+1] = uint8(px.data[c] and 0xFF)
        p += 2
    (outb, buildUncCV0(16, 0, 1, [4, 5, 6]), buildCmpd([4, 5, 6]), @[16, 16, 16], w, h)
  of dkRgba16:
    var outb = newSeq[uint8](int(w) * int(h) * 8)
    var p = 0
    for px in img.rgba16.pixels:
      for c in 0 ..< 4:
        outb[p] = uint8(px.data[c] shr 8); outb[p+1] = uint8(px.data[c] and 0xFF)
        p += 2
    (outb, buildUncCV0(16, 0, 1, [4, 5, 6, 7]), buildCmpd([4, 5, 6, 7]),
      @[16, 16, 16, 16], w, h)
  of dkLuma16:
    var outb = newSeq[uint8](int(w) * int(h) * 2)
    var p = 0
    for px in img.luma16.pixels:
      outb[p] = uint8(px.data[0] shr 8); outb[p+1] = uint8(px.data[0] and 0xFF)
      p += 2
    (outb, buildUncCV0(16, 0, 0, [1]), buildCmpd([1]), @[16], w, h)
  else:
    # Downconvert exotic kinds via 8-bit views where possible
    if img.kind == dkLumaA8 or img.kind == dkLumaA16:
      raise newException(CatchableError, "heif writer: alpha-gray unsupported")
    raise newException(CatchableError, "heif writer: color kind unsupported")

# --- Box builders ---

proc buildFtyp*(major: string, compat: seq[string]): seq[uint8] =
  var p: seq[uint8] = @[]
  p.put4CC(major)
  p.putU32BE(0)
  for c in compat: p.put4CC(c)
  makeBox("ftyp", p)

proc buildHdlr*(): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putU32BE(0) # pre_defined
  p.put4CC("pict")
  for i in 0 ..< 12: p.add(0)
  p.add(0) # name NUL
  makeFullBox("hdlr", 0, 0, p)

proc buildPitm*(id: uint32): seq[uint8] =
  var p: seq[uint8] = @[]
  if id < 65536:
    var q: seq[uint8] = @[]
    q.putU16BE(uint16(id))
    result = makeFullBox("pitm", 0, 0, q)
  else:
    var q: seq[uint8] = @[]
    q.putU32BE(id)
    result = makeFullBox("pitm", 1, 0, q)

proc buildInfe*(id: uint32, typ: string, hidden: bool,
    name = "", contentType = ""): seq[uint8] =
  var p: seq[uint8] = @[]
  if id < 65536:
    p.putU16BE(uint16(id))
    p.putU16BE(0)
  else:
    p.putU32BE(id)
    p.putU32BE(0)
  p.put4CC(typ)
  for c in name: p.add(uint8(c))
  p.add(0)
  if typ == "mime":
    for c in contentType: p.add(uint8(c))
    p.add(0)
  elif typ == "uri ":
    for c in contentType: p.add(uint8(c))
    p.add(0)
  let flags = if hidden: 1'u32 else: 0'u32
  if id < 65536: makeFullBox("infe", 2, flags, p)
  else: makeFullBox("infe", 3, flags, p)

proc buildIinf*(items: seq[tuple[id: uint32, typ: string, hidden: bool,
    name: string, ctype: string]]): seq[uint8] =
  let use32 = block:
    var b = false
    for it in items:
      if it.id >= 65536: b = true
    b
  if not use32:
    # iinf v0 wraps count + entries directly (no extra box layer)
    result = @[]
    var inner: seq[uint8] = @[]
    inner.putFullHeader(0, 0)
    inner.putU16BE(uint16(items.len))
    for it in items: inner.putBytes(buildInfe(it.id, it.typ, it.hidden,
      it.name, it.ctype))
    result = makeBox("iinf", inner)
  else:
    var inner: seq[uint8] = @[]
    inner.putFullHeader(1, 0)
    inner.putU32BE(uint32(items.len))
    for it in items: inner.putBytes(buildInfe(it.id, it.typ, it.hidden,
      it.name, it.ctype))
    result = makeBox("iinf", inner)

proc buildIloc*(entries: seq[tuple[id: uint32, offset, length: int]]): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putFullHeader(0, 0)
  p.add(0x44); p.add(0x40) # off=4 len=4 base=4
  p.putU16BE(uint16(entries.len))
  for e in entries:
    p.putU16BE(uint16(e.id))
    p.putU16BE(0) # data_reference_index
    p.putU32BE(0) # base_offset
    p.putU16BE(1) # extent_count
    p.putU32BE(uint32(e.offset))
    p.putU32BE(uint32(e.length))
  makeBox("iloc", p)

proc buildIref*(refs: seq[tuple[fromId: uint32, typ: string,
    toIds: seq[uint32]]]): seq[uint8] =
  if refs.len == 0: return @[]
  var p: seq[uint8] = @[]
  p.putFullHeader(0, 0)
  for r in refs:
    var e: seq[uint8] = @[]
    e.putU16BE(uint16(r.fromId))
    e.putU16BE(uint16(r.toIds.len))
    for t in r.toIds: e.putU16BE(uint16(t))
    # entry box: size + type + payload
    var eb: seq[uint8] = @[]
    eb.putU32BE(uint32(8 + e.len))
    eb.put4CC(r.typ)
    eb.putBytes(e)
    p.putBytes(eb)
  makeBox("iref", p)

proc buildIprp*(propPayloads: seq[tuple[kind: string,
    payload: seq[uint8]]],
    assocs: seq[seq[tuple[idx: int, essential: bool]]]): seq[uint8] =
  var ipcoInner: seq[uint8] = @[]
  for pr in propPayloads:
    ipcoInner.putBytes(makeBox(pr.kind, pr.payload))
  let ipco = makeBox("ipco", ipcoInner)
  var ipmaP: seq[uint8] = @[]
  ipmaP.putFullHeader(0, 0)
  ipmaP.putU32BE(uint32(assocs.len))
  for ai, alist in assocs:
    ipmaP.putU16BE(uint16(ai + 1)) # item id (1-based here; remapped by caller)
    ipmaP.add(uint8(alist.len))
    for a in alist:
      var b = uint8(a.idx and 0x7F)
      if a.essential: b = b or 0x80
      ipmaP.add(b)
  let ipma = makeBox("ipma", ipmaP)
  makeBox("iprp", ipco & ipma)

# --- Collection writer ---

proc sKindIsEmpty*(s: HeifItemSpec): bool =
  s.kind == hikIden

proc itemTypeOf*(s: HeifItemSpec): string =
  case s.kind
  of hikUnc: result = "unci"
  of hikJpeg: result = "jpeg"
  of hikGrid: result = "grid"
  of hikOverlay: result = "iovl"
  of hikIden: result = "iden"
  of hikExif: result = "Exif"
  of hikMime: result = "mime"
  of hikUri: result = "uri "

proc writeCollection*(coll: HeifCollection): ImageResult[seq[uint8]] =
  if coll.items.len == 0 or coll.items.len > 100:
    return err[seq[uint8]](encodingError("heif: bad collection size"))
  if coll.primary < 0 or coll.primary >= coll.items.len:
    return err[seq[uint8]](encodingError("heif: bad primary index"))
  let pk = coll.items[coll.primary].kind
  if pk == hikExif or pk == hikMime or pk == hikUri:
    return err[seq[uint8]](encodingError("heif: primary must be an image"))
  # 1. Item data blobs
  var blobs = newSeq[seq[uint8]](coll.items.len)
  var ispeWH = newSeq[tuple[w, h: uint32]](coll.items.len)
  try:
    for i, s in coll.items:
      case s.kind
      of hikUnc:
        let (bytes, u, c, pixi, w, h) = encodeUncFrame(s.image)
        blobs[i] = bytes
        ispeWH[i] = (w, h)
      of hikJpeg:
        let enc = encodeJpeg(s.image, s.jpegQuality)
        if not enc.ok: return err[seq[uint8]](enc.err)
        blobs[i] = enc.value
        let (w, h) = s.image.dimensions()
        ispeWH[i] = (w, h)
      of hikGrid:
        blobs[i] = buildGrid(s.gridRows, s.gridCols, s.gridOutW, s.gridOutH)
        ispeWH[i] = (uint32(s.gridOutW), uint32(s.gridOutH))
      of hikOverlay:
        blobs[i] = buildOverlay(s.overlayOutW, s.overlayOutH, s.overlayOffs)
        ispeWH[i] = (uint32(s.overlayOutW), uint32(s.overlayOutH))
      of hikIden:
        blobs[i] = @[]
        ispeWH[i] = (s.ispeW, s.ispeH)
      of hikExif, hikMime, hikUri:
        blobs[i] = s.metaBytes
  except CatchableError as e:
    return err[seq[uint8]](encodingError("heif: " & e.msg))
  # 2. Properties per item (dedup later)
  type Prop = tuple[kind: string, payload: seq[uint8]]
  var perItemProps = newSeq[seq[Prop]](coll.items.len)
  var perItemEss = newSeq[seq[bool]](coll.items.len)
  proc addProp(i: int, kind: string, payload: seq[uint8], ess = false) =
    perItemProps[i].add((kind, payload))
    perItemEss[i].add(ess)
  try:
    for i, s in coll.items:
      case s.kind
      of hikUnc:
        let img = s.image
        let (w, h) = img.dimensions()
        addProp(i, "ispe", buildIspe(w, h))
        # uncC / cmpd / pixi
        let (_, u, c, pixi, _, _) = encodeUncFrame(img)
        addProp(i, "uncC", u, true)
        if c.len > 0: addProp(i, "cmpd", c)
        addProp(i, "pixi", buildPixi(pixi))
        addProp(i, "colr", buildNclx(1, 13, 6, true))
      of hikJpeg:
        let (w, h) = s.image.dimensions()
        addProp(i, "ispe", buildIspe(w, h))
        addProp(i, "colr", buildNclx(1, 13, 1, true))
      of hikGrid, hikOverlay, hikIden:
        addProp(i, "ispe", buildIspe(ispeWH[i][0], ispeWH[i][1]))
      of hikExif, hikMime, hikUri:
        discard
      if s.auxType.len > 0:
        addProp(i, "auxC", buildAuxC(s.auxType))
      if s.irotTurns >= 0:
        addProp(i, "irot", buildIrot(s.irotTurns), true)
      if s.imirTopBottom >= 0:
        addProp(i, "imir", buildImir(s.imirTopBottom == 0), true)
      if s.clapRect.has:
        addProp(i, "clap", buildClap(s.clapRect.w, 1, s.clapRect.h, 1,
          s.clapRect.x, s.clapRect.y), true)
  except CatchableError as e:
    return err[seq[uint8]](encodingError("heif: prop build: " & e.msg))
  # 3. Dedup properties into ipco index
  var uniq: seq[Prop] = @[]
  var assocIdx = newSeq[seq[tuple[idx: int, essential: bool]]](coll.items.len)
  for i in 0 ..< coll.items.len:
    var al: seq[tuple[idx: int, essential: bool]] = @[]
    for pi in 0 ..< perItemProps[i].len:
      let pr = perItemProps[i][pi]
      let ess = perItemEss[i][pi]
      var found = -1
      for ui, u in uniq:
        if u.kind == pr.kind and u.payload == pr.payload:
          found = ui
          break
      if found < 0:
        uniq.add(pr)
        found = uniq.len - 1
      al.add((found + 1, ess))
    assocIdx[i] = al
  # 4. References
  type Ref = tuple[fromId: uint32, typ: string, toIds: seq[uint32]]
  var refs: seq[Ref] = @[]
  for i, s in coll.items:
    let fid = uint32(i + 1)
    if s.thmbTo >= 0:
      refs.add((fid, "thmb", @[uint32(s.thmbTo + 1)]))
    if s.auxType.len > 0:
      # aux -> master: writer caller sets thmbTo-style? use first non-aux
      # For now link aux items to primary if no explicit master.
      refs.add((fid, "auxl", @[uint32(coll.primary + 1)]))
    if s.dimgTo.len > 0:
      var tids: seq[uint32] = @[]
      for t in s.dimgTo: tids.add(uint32(t + 1))
      refs.add((fid, "dimg", tids))
    if s.cdscTo.len > 0:
      var tids: seq[uint32] = @[]
      for t in s.cdscTo: tids.add(uint32(t + 1))
      refs.add((fid, "cdsc", tids))
  # 5. Layout: compute sizes with placeholder iloc, then final offsets
  let brandMajor = if coll.brand.len == 4: coll.brand else: "mif1"
  var compat = @["mif1", "miaf", "1pic"]
  var hasJpeg = false
  var hasUnc = false
  for s in coll.items:
    if s.kind == hikJpeg: hasJpeg = true
    if s.kind == hikUnc: hasUnc = true
  if hasJpeg: compat.add("jpeg")
  if hasUnc: compat.add("unci")
  let ftyp = buildFtyp(brandMajor, compat)
  # iprp needs item ids remapped (assocIdx is 0-based order; buildIprp
  # expects 1-based sequential which matches our ids)
  let iprp = buildIprp(uniq, assocIdx)
  let hdlr = buildHdlr()
  let pitm = buildPitm(uint32(coll.primary + 1))
  var iinfItems: seq[tuple[id: uint32, typ: string, hidden: bool,
      name: string, ctype: string]] = @[]
  for i, s in coll.items:
    case s.kind
    of hikMime:
      iinfItems.add((uint32(i + 1), itemTypeOf(s), s.hidden, "", s.mimeType))
    of hikUri:
      iinfItems.add((uint32(i + 1), itemTypeOf(s), s.hidden, "", s.uriType))
    of hikExif:
      iinfItems.add((uint32(i + 1), itemTypeOf(s), s.hidden, "", ""))
    else:
      iinfItems.add((uint32(i + 1), itemTypeOf(s), s.hidden, "", ""))
  let iinf = buildIinf(iinfItems)
  let iref = buildIref(refs)
  let grpl = buildGroupsBox(coll.groups)
  # iloc placeholder to measure meta size
  var dummyEntries: seq[tuple[id: uint32, offset, length: int]] = @[]
  for i, b in blobs:
    dummyEntries.add((uint32(i + 1), 0, b.len))
  let ilocDummy = buildIloc(dummyEntries)
  var metaInnerLen = 4 + hdlr.len + pitm.len + ilocDummy.len + iinf.len +
    iprp.len + iref.len + grpl.len
  let metaLen = 8 + metaInnerLen
  let mdatStart = ftyp.len + metaLen + 8
  var entries: seq[tuple[id: uint32, offset, length: int]] = @[]
  var cur = mdatStart
  for i, b in blobs:
    if sKindIsEmpty(coll.items[i]):
      entries.add((uint32(i + 1), 0, 0))
    else:
      entries.add((uint32(i + 1), cur, b.len))
      cur += b.len
  let iloc = buildIloc(entries)
  # rebuild meta with final iloc (same size as dummy)
  doAssert iloc.len == ilocDummy.len
  var metaPayload: seq[uint8] = @[]
  metaPayload.putFullHeader(0, 0)
  metaPayload.putBytes(hdlr)
  metaPayload.putBytes(pitm)
  metaPayload.putBytes(iloc)
  metaPayload.putBytes(iinf)
  metaPayload.putBytes(iprp)
  if iref.len > 0: metaPayload.putBytes(iref)
  if grpl.len > 0: metaPayload.putBytes(grpl)
  let meta = makeBox("meta", metaPayload)
  doAssert meta.len == metaLen
  var mdatPayload: seq[uint8] = @[]
  for i, b in blobs:
    if not sKindIsEmpty(coll.items[i]):
      mdatPayload.putBytes(b)
  let mdat = makeBox("mdat", mdatPayload)
  ok(ftyp & meta & mdat)

proc encodeHeif*(img: DynamicImage): ImageResult[seq[uint8]] =
  var coll = HeifCollection(primary: 0, brand: "mif1")
  coll.items.add(defaultItemSpec(img))
  writeCollection(coll)

proc encodeHeifJpeg*(img: DynamicImage, quality = 90): ImageResult[seq[uint8]] =
  var s = defaultItemSpec(img)
  s.kind = hikJpeg
  s.jpegQuality = quality
  var coll = HeifCollection(primary: 0, brand: "mif1")
  coll.items.add(s)
  writeCollection(coll)
