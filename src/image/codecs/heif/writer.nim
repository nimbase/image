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
import ./sequence
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
    hikPass ## passthrough coded still (evc1, hvc1, vvc1, avc1, j2k1, ...)

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
    ispeW*, ispeH*: uint32 ## explicit extents for derived/iden/pass
    auxType*: string ## "" = not aux
    thmbTo*: int ## -1 = none, else collection index of master
    dimgTo*: seq[int] ## for iden/grid/overlay
    cdscTo*: seq[int] ## metadata describes these items
    ilocTo*: seq[int] ## construction-2 sources (virtual tiling); empty = flat
    useIdat*: bool ## store bytes in meta/idat with construction-1
    mimeType*: string ## for hikMime
    uriType*: string ## for hikUri
    metaBytes*: seq[uint8] ## raw payload for Exif/mime/uri
    passType*: string ## 4CC for hikPass, e.g. "evc1"
    passConfigKind*: string ## e.g. "evcC", "" = none
    passConfig*: seq[uint8] ## raw property payload (incl. FullBox if any)
    passBytes*: seq[uint8] ## coded bytes for hikPass
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

type
  IlocEntry* = object
    id*: uint32
    construction*: int ## 0=file, 1=idat, 2=item
    extents*: seq[tuple[srcIndex: int, offset, length: int]]

proc buildIlocEx*(entries: seq[IlocEntry]): seq[uint8] =
  ## v1 with 4-byte ids, off/len/base = 4, index = 2. Same size for
  ## dummy/final when constructions and extent counts match.
  var p: seq[uint8] = @[]
  p.putFullHeader(1, 0)
  p.add(0x44); p.add(0x42) # off=4 len=4 base=4 idx=2
  p.putU16BE(uint16(entries.len))
  for e in entries:
    p.putU32BE(e.id)
    p.add(uint8(e.construction))
    p.putU16BE(0) # data_reference_index
    p.putU32BE(0) # base_offset
    p.putU16BE(uint16(e.extents.len))
    for ex in e.extents:
      p.putU16BE(uint16(ex.srcIndex))
      p.putU32BE(uint32(ex.offset))
      p.putU32BE(uint32(ex.length))
  makeBox("iloc", p)

proc buildIdat*(payload: seq[uint8]): seq[uint8] =
  makeBox("idat", payload)

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
  s.kind == hikIden or
    (s.ilocTo.len > 0) # virtual: no direct mdat bytes

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
  of hikPass:
    if s.passType.len == 4: result = s.passType
    else: result = "evc1"

proc writeCollection*(coll: HeifCollection): ImageResult[seq[uint8]] =
  if coll.items.len == 0 or coll.items.len > 100:
    return err[seq[uint8]](encodingError("heif: bad collection size"))
  if coll.primary < 0 or coll.primary >= coll.items.len:
    return err[seq[uint8]](encodingError("heif: bad primary index"))
  let pk = coll.items[coll.primary].kind
  if pk == hikExif or pk == hikMime or pk == hikUri:
    return err[seq[uint8]](encodingError("heif: primary must be an image"))
  # Validate tiling / idat / passthrough refs up front.
  for i, s in coll.items:
    for t in s.ilocTo:
      if t < 0 or t >= coll.items.len or t == i:
        return err[seq[uint8]](encodingError("heif: bad ilocTo index"))
      if coll.items[t].ilocTo.len > 0:
        return err[seq[uint8]](encodingError("heif: nested virtual tiling"))
    if s.kind == hikPass:
      if s.passType.len != 4:
        return err[seq[uint8]](encodingError("heif: bad passthrough type"))
      if s.ispeW == 0 or s.ispeH == 0 or s.ispeW > 16384 or s.ispeH > 16384:
        return err[seq[uint8]](encodingError("heif: bad passthrough extents"))
    if s.ilocTo.len > 0 and s.useIdat:
      return err[seq[uint8]](encodingError("heif: virtual item cannot use idat"))
    # Derivation reference validation (spec §6.6.2: iden exactly 1 dimg,
    # grid count must equal rows*cols, overlay needs >= 1 input).
    if s.kind == hikIden and s.dimgTo.len != 1:
      return err[seq[uint8]](encodingError("heif: iden needs exactly 1 dimg"))
    if s.kind == hikGrid:
      if s.gridRows < 1 or s.gridCols < 1 or
          s.gridRows * s.gridCols > 256 or s.dimgTo.len != s.gridRows * s.gridCols:
        return err[seq[uint8]](encodingError("heif: bad grid references"))
      if s.gridOutW < 1 or s.gridOutH < 1 or s.gridOutW > 16384 or
          s.gridOutH > 16384:
        return err[seq[uint8]](encodingError("heif: bad grid output"))
    if s.kind == hikOverlay:
      if s.dimgTo.len < 1 or s.dimgTo.len != s.overlayOffs.len:
        return err[seq[uint8]](encodingError("heif: bad overlay references"))
      if s.overlayOutW < 1 or s.overlayOutH < 1 or s.overlayOutW > 16384 or
          s.overlayOutH > 16384:
        return err[seq[uint8]](encodingError("heif: bad overlay canvas"))
  # 1. Item data blobs
  var blobs = newSeq[seq[uint8]](coll.items.len)
  var ispeWH = newSeq[tuple[w, h: uint32]](coll.items.len)
  try:
    for i, s in coll.items:
      case s.kind
      of hikUnc:
        if s.ilocTo.len > 0:
          let (w, h) = s.image.dimensions()
          if w == 0 or h == 0 or w > 16384 or h > 16384:
            return err[seq[uint8]](encodingError("heif: bad virtual extents"))
          blobs[i] = @[] # virtual: assembled from sources
          ispeWH[i] = (w, h)
        else:
          let (bytes, u, c, pixi, w, h) = encodeUncFrame(s.image)
          discard u; discard c; discard pixi
          blobs[i] = bytes
          ispeWH[i] = (w, h)
      of hikJpeg:
        let enc = encodeJpeg(s.image, s.jpegQuality)
        if not enc.ok: return err[seq[uint8]](enc.err)
        if s.ilocTo.len > 0:
          return err[seq[uint8]](encodingError("heif: jpeg virtual unsupported"))
        blobs[i] = enc.value
        let (w, h) = s.image.dimensions()
        ispeWH[i] = (w, h)
      of hikGrid:
        if s.ilocTo.len > 0:
          return err[seq[uint8]](encodingError("heif: grid virtual unsupported"))
        blobs[i] = buildGrid(s.gridRows, s.gridCols, s.gridOutW, s.gridOutH)
        ispeWH[i] = (uint32(s.gridOutW), uint32(s.gridOutH))
      of hikOverlay:
        if s.ilocTo.len > 0:
          return err[seq[uint8]](encodingError("heif: overlay virtual unsupported"))
        blobs[i] = buildOverlay(s.overlayOutW, s.overlayOutH, s.overlayOffs)
        ispeWH[i] = (uint32(s.overlayOutW), uint32(s.overlayOutH))
      of hikIden:
        blobs[i] = @[]
        ispeWH[i] = (s.ispeW, s.ispeH)
      of hikExif, hikMime, hikUri:
        if s.ilocTo.len > 0:
          return err[seq[uint8]](encodingError("heif: metadata virtual unsupported"))
        blobs[i] = s.metaBytes
      of hikPass:
        if s.ilocTo.len > 0:
          return err[seq[uint8]](encodingError("heif: pass virtual unsupported"))
        blobs[i] = s.passBytes
        ispeWH[i] = (s.ispeW, s.ispeH)
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
      of hikPass:
        addProp(i, "ispe", buildIspe(ispeWH[i][0], ispeWH[i][1]))
        if s.passConfigKind.len == 4 and s.passConfig.len > 0:
          addProp(i, s.passConfigKind, s.passConfig, true)
        addProp(i, "colr", buildNclx(1, 13, 1, true))
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
    if s.ilocTo.len > 0:
      var tids: seq[uint32] = @[]
      for t in s.ilocTo: tids.add(uint32(t + 1))
      refs.add((fid, "iloc", tids))
  # 5. Layout: idat + iloc v1 (constructions 0/1/2), then final offsets
  let brandMajor = if coll.brand.len == 4: coll.brand else: "mif1"
  var compat = @["mif1", "miaf", "1pic"]
  var hasJpeg = false
  var hasUnc = false
  var extraBrands: seq[string] = @[]
  for s in coll.items:
    if s.kind == hikJpeg: hasJpeg = true
    if s.kind == hikUnc: hasUnc = true
    if s.kind == hikPass:
      case s.passType
      of "hvc1", "hev1", "lhv1": extraBrands.add(["heic", "hevc"])
      of "vvc1", "vvi1": extraBrands.add(["vvic"])
      of "avc1": extraBrands.add(["avci"])
      of "avci", "avcs": extraBrands.add([s.passType])
      of "evc1", "evci": extraBrands.add(["evc1"])
      of "j2k1": extraBrands.add(["j2ki"])
      else: extraBrands.add([s.passType])
  if hasJpeg: compat.add("jpeg")
  if hasUnc: compat.add("unci")
  for b in extraBrands:
    if b notin compat: compat.add(b)
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
  # idat payload: concat of useIdat blobs in item order.
  var idatPayload: seq[uint8] = @[]
  var idatRel = newSeq[int](coll.items.len) # relative offset inside idat
  for i, b in blobs:
    if coll.items[i].useIdat and not sKindIsEmpty(coll.items[i]):
      idatRel[i] = idatPayload.len
      idatPayload.putBytes(b)
  let idatBox = if idatPayload.len > 0: buildIdat(idatPayload) else: @[]
  # iloc entries with constructions.
  proc makeEntries(mdatStart: int): seq[IlocEntry] =
    result = @[]
    var cur = mdatStart
    # idat relative offsets already in idatRel; mdat offsets assigned here
    var mdatCur = cur
    for i in 0 ..< coll.items.len:
      let s = coll.items[i]
      if s.ilocTo.len > 0:
        var ex: seq[tuple[srcIndex: int, offset, length: int]] = @[]
        var pos = 1
        for t in s.ilocTo:
          ex.add((pos, 0, blobs[t].len))
          inc(pos)
        result.add(IlocEntry(id: uint32(i + 1), construction: 2,
          extents: ex))
      elif sKindIsEmpty(s) and s.ilocTo.len == 0:
        # iden has no item body per spec §6.6.2.1 (zero extents).
        result.add(IlocEntry(id: uint32(i + 1), construction: 0,
          extents: newSeq[tuple[srcIndex: int, offset, length: int]]()))
      elif s.useIdat:
        result.add(IlocEntry(id: uint32(i + 1), construction: 1,
          extents: @[(0, idatRel[i], blobs[i].len)]))
      else:
        result.add(IlocEntry(id: uint32(i + 1), construction: 0,
          extents: @[(0, mdatCur, blobs[i].len)]))
        mdatCur += blobs[i].len
  # Dummy to measure meta size (same shape, zero offsets).
  var dummyEx: seq[IlocEntry] = @[]
  for i in 0 ..< coll.items.len:
    let s = coll.items[i]
    if s.ilocTo.len > 0:
      var ex: seq[tuple[srcIndex: int, offset, length: int]] = @[]
      var pos = 1
      for t in s.ilocTo:
        ex.add((pos, 0, blobs[t].len))
        inc(pos)
      dummyEx.add(IlocEntry(id: uint32(i + 1), construction: 2, extents: ex))
    elif sKindIsEmpty(s):
      dummyEx.add(IlocEntry(id: uint32(i + 1), construction: 0,
        extents: newSeq[tuple[srcIndex: int, offset, length: int]]()))
    elif s.useIdat:
      dummyEx.add(IlocEntry(id: uint32(i + 1), construction: 1,
        extents: @[(0, 0, blobs[i].len)]))
    else:
      dummyEx.add(IlocEntry(id: uint32(i + 1), construction: 0,
        extents: @[(0, 0, blobs[i].len)]))
  let ilocDummy = buildIlocEx(dummyEx)
  var metaInnerLen = 4 + hdlr.len + pitm.len + ilocDummy.len + iinf.len +
    iprp.len + iref.len + grpl.len + idatBox.len
  let metaLen = 8 + metaInnerLen
  let mdatStart = ftyp.len + metaLen + 8
  let entries = makeEntries(mdatStart)
  let iloc = buildIlocEx(entries)
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
  if idatBox.len > 0: metaPayload.putBytes(idatBox)
  let meta = makeBox("meta", metaPayload)
  doAssert meta.len == metaLen
  var mdatPayload: seq[uint8] = @[]
  for i, b in blobs:
    let s = coll.items[i]
    if s.ilocTo.len > 0: continue
    if sKindIsEmpty(s) and s.ilocTo.len == 0:
      # iden empty: skip unless it somehow has bytes (no)
      continue
    if s.useIdat: continue # in idat
    if b.len > 0: mdatPayload.putBytes(b)
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

# --- Timed sequence writer (moov/pict, 1 sample per chunk) ---

proc writeHeifSequence*(frames: seq[DynamicImage],
    kind: HeifItemKind = hikUnc, jpegQuality = 90,
    timescale: uint32 = 1, frameDuration: uint32 = 1): ImageResult[seq[uint8]] =
  if frames.len == 0 or frames.len > 100000:
    return err[seq[uint8]](encodingError("heif: bad sequence length"))
  if kind != hikUnc and kind != hikJpeg:
    return err[seq[uint8]](encodingError("heif: sequence kind must be unci/jpeg"))
  if timescale == 0 or frameDuration == 0:
    return err[seq[uint8]](encodingError("heif: bad sequence timing"))
  var sampleBytes = newSeq[seq[uint8]](frames.len)
  var w0: uint32 = 0
  var h0: uint32 = 0
  var codecBoxes: seq[uint8] = @[]
  var coding = ""
  try:
    for i, f in frames:
      let (w, h) = f.dimensions()
      if i == 0:
        w0 = w; h0 = h
        if w == 0 or h == 0 or w > 16384 or h > 16384:
          return err[seq[uint8]](encodingError("heif: bad sequence size"))
      elif w != w0 or h != h0:
        return err[seq[uint8]](encodingError("heif: sequence size mismatch"))
      if kind == hikUnc:
        let (bytes, u, c, pixi, _, _) = encodeUncFrame(f)
        let boxes =
          if c.len > 0: @[makeBox("uncC", u), makeBox("cmpd", c),
            makeBox("pixi", buildPixi(pixi))]
          else: @[makeBox("uncC", u)]
        var flat: seq[uint8] = @[]
        for b in boxes: flat.putBytes(b)
        if i == 0:
          codecBoxes = flat
          coding = "unci"
        elif flat != codecBoxes:
          return err[seq[uint8]](encodingError("heif: sequence profile mismatch"))
        sampleBytes[i] = bytes
      else:
        let enc = encodeJpeg(f, jpegQuality)
        if not enc.ok: return err[seq[uint8]](enc.err)
        coding = "jpeg"
        sampleBytes[i] = enc.value
  except CatchableError as e:
    return err[seq[uint8]](encodingError("heif: " & e.msg))
  var sizes: seq[int] = @[]
  for b in sampleBytes: sizes.add(b.len)
  let entryBoxes = if coding == "unci": @[codecBoxes] else: newSeq[seq[uint8]]()
  let entry = buildVisualEntry(coding, int(w0), int(h0), entryBoxes)
  let stsd = buildStsd(@[entry])
  let stts = buildStts(frames.len, frameDuration)
  let stsc = buildStsc(sampleBytes.len)
  let stsz = buildStsz(sizes)
  # Dummy stco to measure moov, then final offsets (same box size).
  let dummyOffsets = newSeq[int](sampleBytes.len)
  let stcoDummy = buildStco(dummyOffsets)
  proc buildMoov(stco: seq[uint8]): seq[uint8] =
    let stbl = makeBox("stbl", stsd & stts & stsc & stsz & stco)
    let minf = makeBox("minf", buildVmhd() & buildDinf() & stbl)
    let mdiaInner = buildMdhd(timescale,
        uint32(frames.len) * frameDuration) &
      buildHdlr() & minf
    let mdia = makeBox("mdia", mdiaInner)
    let trakInner = buildTkhd(1, uint32(frames.len) * frameDuration,
        int(w0), int(h0)) & mdia
    let trak = makeBox("trak", trakInner)
    let moovInner = buildMvhd(timescale,
        uint32(frames.len) * frameDuration) & trak
    makeBox("moov", moovInner)
  let moovDummy = buildMoov(stcoDummy)
  let brandMajor = "msf1"
  var compat = @["msf1", "mif1", "miaf", "1pic"]
  if coding == "unci": compat.add("unci")
  else: compat.add("jpeg")
  let ftyp = buildFtyp(brandMajor, compat)
  let mdatStart = ftyp.len + moovDummy.len + 8
  var offs: seq[int] = @[]
  var cur = mdatStart
  for b in sampleBytes:
    offs.add(cur)
    cur += b.len
  let stco = buildStco(offs)
  doAssert stco.len == stcoDummy.len
  let moov = buildMoov(stco)
  doAssert moov.len == moovDummy.len
  var mdatPayload: seq[uint8] = @[]
  for b in sampleBytes: mdatPayload.putBytes(b)
  let mdat = makeBox("mdat", mdatPayload)
  ok(ftyp & moov & mdat)
