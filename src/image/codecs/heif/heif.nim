## HEIF/HEIC facade (clean-room): container + uncompressed + JPEG-in-HEIF
## decode. Item/box layout per ISO/IEC 23008-12; uncompressed descriptors
## per ISO/IEC 23001-17. HEVC/VVC/AVC/JPEG2000 bitstreams, tiled layouts,
## grids/overlays and sequences stay Unsupported (pure-Nim v1 has no video
## or wavelet decoders — same precedent as AVIF bitstream).
import ../../error
import ../../buffer
import ../../dynamic
import ../../math
import ../jpgdec
import ./isobmff
import ./items
import ./props
import ./unc
import ./derived
import ./groups
import ./writer

export groups
export writer
export derived

proc rotateCcw[P](img: ImageBuffer[P], turns: int): ImageBuffer[P] =
  let t = ((turns mod 4) + 4) mod 4
  if t == 0: return img
  let w = int(img.width)
  let h = int(img.height)
  if t == 2:
    var px = newSeq[P](w * h)
    for y in 0 ..< h:
      for x in 0 ..< w:
        px[(h - 1 - y) * w + (w - 1 - x)] = img.pixels[y * w + x]
    return ImageBuffer[P](width: img.width, height: img.height, pixels: px)
  let nw = if t mod 2 == 1: h else: w
  let nh = if t mod 2 == 1: w else: h
  var px = newSeq[P](nw * nh)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let (nx, ny) =
        if t == 1: (y, w - 1 - x)
        else: (h - 1 - y, x)
      px[ny * nw + nx] = img.pixels[y * w + x]
  ImageBuffer[P](width: uint32(nw), height: uint32(nh), pixels: px)

proc flipImg[P](img: ImageBuffer[P], topBottom: bool): ImageBuffer[P] =
  ## topBottom=true exchanges top and bottom rows (imir axis 0);
  ## false exchanges left and right columns (imir axis 1). 23008-12 §6.5.12.3.
  let w = int(img.width)
  let h = int(img.height)
  var px = newSeq[P](w * h)
  for y in 0 ..< h:
    for x in 0 ..< w:
      let (nx, ny) =
        if topBottom: (x, h - 1 - y) else: (w - 1 - x, y)
      px[ny * w + nx] = img.pixels[y * w + x]
  ImageBuffer[P](width: img.width, height: img.height, pixels: px)

const KnownDescriptive = ["ispe", "pixi", "colr", "hvcC", "lhvC", "vvcC",
  "avcC", "jpgC", "j2kH", "uncC", "cmpd", "cmpC", "pasp", "auxC", "rloc",
  "lsel", "clli", "mdcv", "cclv", "amve", "ndwt", "rref", "tols", "subs",
  "oinf", "udes", "altt", "crtt", "mdft"]
const KnownTransformative = ["irot", "imir", "clap", "iscl"]

proc scaleNearest[P](img: ImageBuffer[P], nw, nh: int): ImageBuffer[P] =
  if nw <= 0 or nh <= 0 or nw > 16384 or nh > 16384:
    raise heifErr("heif: bad iscl target")
  let sw = int(img.width)
  let sh = int(img.height)
  var px = newSeq[P](nw * nh)
  for y in 0 ..< nh:
    let sy = min(sh - 1, (y * sh) div nh)
    for x in 0 ..< nw:
      let sx = min(sw - 1, (x * sw) div nw)
      px[y * nw + x] = img.pixels[sy * sw + sx]
  ImageBuffer[P](width: uint32(nw), height: uint32(nh), pixels: move(px))

proc applyTransforms(img: DynamicImage,
    props: seq[RawProperty]): ImageResult[DynamicImage] =
  ## irot/imir/clap/iscl in property order (23008-12 transformative order).
  var cur = img
  for pr in props:
    if pr.kind == "irot":
      let r = parseIrot(pr.payload)
      if r.quarterTurns != 0:
        case cur.kind
        of dkRgb8: cur.rgb8 = rotateCcw(cur.rgb8, r.quarterTurns)
        of dkRgba8: cur.rgba8 = rotateCcw(cur.rgba8, r.quarterTurns)
        of dkLuma8: cur.luma8 = rotateCcw(cur.luma8, r.quarterTurns)
        of dkRgb16: cur.rgb16 = rotateCcw(cur.rgb16, r.quarterTurns)
        of dkRgba16: cur.rgba16 = rotateCcw(cur.rgba16, r.quarterTurns)
        of dkLuma16: cur.luma16 = rotateCcw(cur.luma16, r.quarterTurns)
        else:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "heif: irot on this color type unsupported"))
    elif pr.kind == "imir":
      let m = parseImir(pr.payload)
      case cur.kind
      of dkRgb8: cur.rgb8 = flipImg(cur.rgb8, m.topBottom)
      of dkRgba8: cur.rgba8 = flipImg(cur.rgba8, m.topBottom)
      of dkLuma8: cur.luma8 = flipImg(cur.luma8, m.topBottom)
      of dkRgb16: cur.rgb16 = flipImg(cur.rgb16, m.topBottom)
      of dkRgba16: cur.rgba16 = flipImg(cur.rgba16, m.topBottom)
      of dkLuma16: cur.luma16 = flipImg(cur.luma16, m.topBottom)
      else:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "heif: imir on this color type unsupported"))
    elif pr.kind == "clap":
      let (w, h) = cur.dimensions()
      let c = clapCrop(parseClap(pr.payload), int(w), int(h))
      let r = initRect(uint32(c.x), uint32(c.y), uint32(c.w), uint32(c.h))
      case cur.kind
      of dkRgb8: cropInPlace(cur.rgb8, r)
      of dkRgba8: cropInPlace(cur.rgba8, r)
      of dkLuma8: cropInPlace(cur.luma8, r)
      of dkRgb16: cropInPlace(cur.rgb16, r)
      of dkRgba16: cropInPlace(cur.rgba16, r)
      of dkLuma16: cropInPlace(cur.luma16, r)
      else:
        return err[DynamicImage](unsupportedError(ukGenericFeature,
          "heif: clap on this color type unsupported"))
    elif pr.kind == "iscl":
      try:
        let s = parseIscl(pr.payload)
        if s.wDen == 0 or s.hDen == 0 or s.wNum == 0 or s.hNum == 0:
          return err[DynamicImage](decodingError("heif: bad iscl"))
        let (w, h) = cur.dimensions()
        let nw = (int(w) * int(s.wNum) + int(s.wDen) - 1) div int(s.wDen)
        let nh = (int(h) * int(s.hNum) + int(s.hDen) - 1) div int(s.hDen)
        case cur.kind
        of dkRgb8: cur.rgb8 = scaleNearest(cur.rgb8, nw, nh)
        of dkRgba8: cur.rgba8 = scaleNearest(cur.rgba8, nw, nh)
        of dkLuma8: cur.luma8 = scaleNearest(cur.luma8, nw, nh)
        of dkRgb16: cur.rgb16 = scaleNearest(cur.rgb16, nw, nh)
        of dkRgba16: cur.rgba16 = scaleNearest(cur.rgba16, nw, nh)
        of dkLuma16: cur.luma16 = scaleNearest(cur.luma16, nw, nh)
        else:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "heif: iscl on this color type unsupported"))
      except HeifDecodeError as e:
        return err[DynamicImage](decodingError(e.msg))
    elif pr.essential:
      var descriptive = false
      for k in KnownDescriptive:
        if pr.kind == k:
          descriptive = true
          break
      if descriptive:
        continue # descriptive props need no application
      # 23008-12 §6.3: essential transformative properties must be applied;
      # anything unhandled (e.g. iscl scaling, transitions) fails cleanly.
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: essential transformative property '" & pr.kind &
          "' unsupported"))
    # non-essential unrecognized properties are ignored per §6.5.1
  ok(cur)

proc propPayload(props: seq[RawProperty], kind: string): seq[uint8] =
  for pr in props:
    if pr.kind == kind: return pr.payload
  @[]

proc hasProp(props: seq[RawProperty], kind: string): bool =
  for pr in props:
    if pr.kind == kind: return true
  false

proc effectiveDescriptive(props: seq[RawProperty]): seq[RawProperty] =
  ## 23008-12 §6.5.1: descriptive properties following the first
  ## transformative or unrecognized property are ignored by readers.
  for pr in props:
    if pr.kind in KnownTransformative: break
    var known = false
    for k in KnownDescriptive:
      if pr.kind == k:
        known = true
        break
    if not known: break
    result.add(pr)

proc decodePrimary(data: seq[uint8], meta: HeifMeta,
    id: uint32, depth = 0): ImageResult[DynamicImage] =
  if depth > 8:
    return err[DynamicImage](decodingError("heif: derivation too deep"))
  let (found, item) = findItem(meta, id)
  if not found:
    return err[DynamicImage](decodingError("heif: primary item not found"))
  if item.typ == "iden":
    # identity: single dimg reference carries the coded image
    for r in meta.refs:
      if r.fromId == id and r.refType == "dimg" and r.toIds.len == 1:
        let inner = decodePrimary(data, meta, r.toIds[0], depth + 1)
        if not inner.ok: return inner
        return applyTransforms(inner.value, itemProps(meta, id))
    return err[DynamicImage](decodingError("heif: bad iden references"))
  if item.typ == "grid":
    var tids: seq[uint32] = @[]
    for r in meta.refs:
      if r.fromId == id and r.refType == "dimg":
        tids = r.toIds
        break
    if tids.len == 0:
      return err[DynamicImage](decodingError("heif: grid missing dimg"))
    var payload: seq[uint8] = @[]
    try:
      payload = itemBytes(data, meta, id)
    except HeifDecodeError as e:
      return err[DynamicImage](decodingError(e.msg))
    var g: GridInfo
    try:
      g = parseGrid(payload)
    except HeifDecodeError as e:
      return err[DynamicImage](decodingError(e.msg))
    if tids.len != g.rows * g.cols:
      return err[DynamicImage](decodingError("heif: grid count mismatch"))
    var tiles: seq[DynamicImage] = @[]
    for t in tids:
      let d = decodePrimary(data, meta, t, depth + 1)
      if not d.ok: return d
      tiles.add(d.value)
    # All tiles must share kind; composite 8-bit RGB/RGBA fast paths.
    if tiles[0].kind == dkRgb8:
      var rgbTiles: seq[RgbImage] = @[]
      for t in tiles:
        if t.kind != dkRgb8:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "heif: mixed grid tile kinds"))
        rgbTiles.add(t.rgb8)
      # Tile sizes must match
      let tw = rgbTiles[0].width
      let th = rgbTiles[0].height
      for t in rgbTiles:
        if t.width != tw or t.height != th:
          return err[DynamicImage](decodingError("heif: grid tile size mismatch"))
      let comp = compositeGridRgb8(rgbTiles, g)
      return applyTransforms(DynamicImage(kind: dkRgb8, rgb8: comp),
        itemProps(meta, id))
    elif tiles[0].kind == dkRgba8:
      var raTiles: seq[RgbaImage] = @[]
      for t in tiles:
        if t.kind != dkRgba8:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "heif: mixed grid tile kinds"))
        raTiles.add(t.rgba8)
      let comp = compositeGridRgba8(raTiles, g)
      return applyTransforms(DynamicImage(kind: dkRgba8, rgba8: comp),
        itemProps(meta, id))
    else:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: grid tile kind unsupported"))
  if item.typ == "iovl":
    var tids: seq[uint32] = @[]
    for r in meta.refs:
      if r.fromId == id and r.refType == "dimg":
        tids = r.toIds
        break
    if tids.len == 0:
      return err[DynamicImage](decodingError("heif: overlay missing dimg"))
    var payload: seq[uint8] = @[]
    try:
      payload = itemBytes(data, meta, id)
    except HeifDecodeError as e:
      return err[DynamicImage](decodingError(e.msg))
    var ov: OverlayInfo
    try:
      ov = parseOverlay(payload, tids.len)
    except HeifDecodeError as e:
      return err[DynamicImage](decodingError(e.msg))
    var layers: seq[DynamicImage] = @[]
    for t in tids:
      let d = decodePrimary(data, meta, t, depth + 1)
      if not d.ok: return d
      layers.add(d.value)
    if layers[0].kind == dkRgb8:
      var rgbLayers: seq[RgbImage] = @[]
      for l in layers:
        if l.kind != dkRgb8:
          return err[DynamicImage](unsupportedError(ukGenericFeature,
            "heif: mixed overlay kinds"))
        rgbLayers.add(l.rgb8)
      let comp = compositeOverlayRgb8(rgbLayers, ov)
      return applyTransforms(DynamicImage(kind: dkRgb8, rgb8: comp),
        itemProps(meta, id))
    else:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: overlay kind unsupported"))
  if item.typ == "hvc1" or item.typ == "hev1" or item.typ == "lhv1":
    return err[DynamicImage](unsupportedError(ukFormat,
      "heif: HEVC bitstream decoding not implemented in pure-Nim v1"))
  if item.typ == "vvc1" or item.typ == "vvi1":
    return err[DynamicImage](unsupportedError(ukFormat,
      "heif: VVC bitstream decoding not implemented in pure-Nim v1"))
  if item.typ == "avc1":
    return err[DynamicImage](unsupportedError(ukFormat,
      "heif: AVC bitstream decoding not implemented in pure-Nim v1"))
  if item.typ == "j2k1":
    return err[DynamicImage](unsupportedError(ukFormat,
      "heif: JPEG2000 bitstream decoding not implemented in pure-Nim v1"))
  for r in meta.refs:
    if r.fromId == id and r.refType == "pred":
      # 23008-12 §6.4.9: predictively coded items need reference
      # concatenation + a video decoder; out of scope for pure-Nim v1.
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: predictively coded item unsupported"))
  if item.typ == "unci":
    let raw = itemBytes(data, meta, id)
    let props = effectiveDescriptive(itemProps(meta, id))
    if not hasProp(props, "ispe") or not hasProp(props, "uncC"):
      return err[DynamicImage](decodingError("heif: unci missing properties"))
    let ext = parseIspe(propPayload(props, "ispe"))
    let prof = parseUncC(propPayload(props, "uncC"))
    var comps: seq[CmpEntry] = @[]
    if not prof.isV1:
      # v0 takes component order from cmpd; v1 profiles imply it
      if not hasProp(props, "cmpd"):
        return err[DynamicImage](decodingError("heif: unci missing cmpd"))
      comps = parseCmpd(propPayload(props, "cmpd"))
      if comps.len == 0:
        return err[DynamicImage](decodingError("heif: missing cmpd"))
    var pixi: PixInfo
    if hasProp(props, "pixi"):
      pixi = parsePixi(propPayload(props, "pixi"))
      if not prof.isV1 and pixi.bits.len != comps.len:
        # v1 profiles imply their layout; observed writers emit
        # pixi counts that do not match (e.g. 1 for rgb3)
        return err[DynamicImage](decodingError("heif: pixi/cmpd mismatch"))
    elif not prof.isV1:
      # pixi is optional when uncC v0 carries per-component depths
      pixi.bits = newSeq[int](comps.len)
      for i in 0 ..< comps.len: pixi.bits[i] = prof.bitDepth
    else:
      return err[DynamicImage](decodingError("heif: unci missing pixi"))
    var matrix = 6
    var full = true
    for pr in props:
      # prefer the nclx description when several colr boxes are present
      # (23008-12 §6.5.5: ICC 'rICC'/'prof' is for display matching)
      if pr.kind == "colr":
        try:
          let nclx = parseNclx(pr.payload)
          matrix = nclx.matrix
          full = nclx.fullRange
          break
        except HeifDecodeError:
          discard
    let frame =
      if hasProp(props, "cmpC"):
        let d = decompressFrame(raw, propPayload(props, "cmpC"),
          ext.width * ext.height * 4)
        if not d.ok: return err[DynamicImage](d.err)
        d.value
      else:
        raw
    let dec = decodeUncompressed(frame, prof, comps, pixi, ext.width,
      ext.height, matrix, full)
    if not dec.ok: return dec
    return applyTransforms(dec.value, props)
  if item.typ == "jpeg":
    let raw = itemBytes(data, meta, id)
    let dec = decodeJpeg(raw)
    if not dec.ok:
      return err[DynamicImage](decodingError(
        "heif: embedded JPEG failed: " & dec.err.msg))
    return applyTransforms(dec.value, itemProps(meta, id))
  err[DynamicImage](unsupportedError(ukFormat,
    "heif: item type '" & item.typ & "' unsupported"))

proc decodeHeif*(data: seq[uint8]): ImageResult[DynamicImage] =
  ## Decode a HEIF/HEIC still (primary item). Handles uncompressed,
  ## JPEG, and derived grid/overlay/identity stills. Video bitstreams
  ## stay Unsupported (passthrough via extractors).
  if data.len < 12:
    return err[DynamicImage](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    if not meta.hasPrimary:
      return err[DynamicImage](decodingError("heif: missing pitm"))
    decodePrimary(data, meta, meta.primaryId)
  except HeifDecodeError as e:
    err[DynamicImage](decodingError(e.msg))

proc listHeifItems*(data: seq[uint8]): ImageResult[seq[HeifItem]] =
  if data.len < 12:
    return err[seq[HeifItem]](decodingError("heif: too short"))
  try:
    ok(parseMeta(data).items)
  except HeifDecodeError as e:
    err[seq[HeifItem]](decodingError(e.msg))

proc decodeHeifItem*(data: seq[uint8], itemId: uint32): ImageResult[DynamicImage] =
  if data.len < 12:
    return err[DynamicImage](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    decodePrimary(data, meta, itemId)
  except HeifDecodeError as e:
    err[DynamicImage](decodingError(e.msg))

proc decodeHeifAll*(data: seq[uint8]): ImageResult[seq[DynamicImage]] =
  ## Decode every top-level image item (master + thumbs). Derived
  ## items are resolved; hidden tiles are included when directly listed.
  if data.len < 12:
    return err[seq[DynamicImage]](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    var outs: seq[DynamicImage] = @[]
    for it in meta.items:
      if it.typ == "unci" or it.typ == "jpeg" or it.typ == "grid" or
          it.typ == "iovl" or it.typ == "iden":
        let d = decodePrimary(data, meta, it.id)
        if d.ok: outs.add(d.value)
    ok(outs)
  except HeifDecodeError as e:
    err[seq[DynamicImage]](decodingError(e.msg))

proc heifGroups*(data: seq[uint8]): ImageResult[seq[EntityGroup]] =
  if data.len < 12:
    return err[seq[EntityGroup]](decodingError("heif: too short"))
  try:
    for b in topLevelBoxes(data):
      if b.isTypeStr("meta"):
        return ok(parseEntityGroups(data, b))
    ok(newSeq[EntityGroup]())
  except HeifDecodeError as e:
    err[seq[EntityGroup]](decodingError(e.msg))

proc heifMetadata*(data: seq[uint8]): ImageResult[seq[tuple[id: uint32,
    typ: string, contentType: string, bytes: seq[uint8]]]] =
  ## List metadata items (Exif / mime / uri) with their raw bytes.
  ## Image items are skipped; cdsc links are available via iref parsing
  ## when needed.
  if data.len < 12:
    return err[seq[tuple[id: uint32, typ: string, contentType: string,
      bytes: seq[uint8]]]](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    var outs: seq[tuple[id: uint32, typ: string, contentType: string,
      bytes: seq[uint8]]] = @[]
    for it in meta.items:
      if it.typ == "Exif" or it.typ == "mime" or it.typ == "uri ":
        outs.add((it.id, it.typ, it.contentType,
          itemBytes(data, meta, it.id)))
    ok(outs)
  except HeifDecodeError as e:
    err[seq[tuple[id: uint32, typ: string, contentType: string,
      bytes: seq[uint8]]]](decodingError(e.msg))

proc decodeHeic*(data: seq[uint8]): ImageResult[DynamicImage] =
  ## Alias: HEIC is HEIF with an HEVC brand; same container path.
  decodeHeif(data)

proc extractItemBytes*(data: seq[uint8]): ImageResult[seq[uint8]] =
  ## Raw coded bytes of the primary item (e.g. JPEG2000 codestream access
  ## for external decoders). Container parse only, never decodes pixels.
  if data.len < 12:
    return err[seq[uint8]](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    if not meta.hasPrimary:
      return err[seq[uint8]](decodingError("heif: missing pitm"))
    ok(itemBytes(data, meta, meta.primaryId))
  except HeifDecodeError as e:
    err[seq[uint8]](decodingError(e.msg))

proc extractJ2kCodestream*(data: seq[uint8]): ImageResult[seq[uint8]] =
  ## Raw JPEG2000 codestream when the primary item is `j2k1`, else an error.
  if data.len < 12:
    return err[seq[uint8]](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    if not meta.hasPrimary:
      return err[seq[uint8]](decodingError("heif: missing pitm"))
    let (found, item) = findItem(meta, meta.primaryId)
    if not found:
      return err[seq[uint8]](decodingError("heif: primary item not found"))
    if item.typ != "j2k1":
      return err[seq[uint8]](decodingError(
        "heif: primary item is not JPEG2000 (" & item.typ & ")"))
    ok(itemBytes(data, meta, meta.primaryId))
  except HeifDecodeError as e:
    err[seq[uint8]](decodingError(e.msg))
