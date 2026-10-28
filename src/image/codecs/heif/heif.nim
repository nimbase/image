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
  "oinf", "udes"]
const KnownTransformative = ["irot", "imir", "clap", "iscl"]

proc applyTransforms(img: DynamicImage,
    props: seq[RawProperty]): ImageResult[DynamicImage] =
  ## irot/imir/clap in property order (23008-12 transformative order).
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
    id: uint32): ImageResult[DynamicImage] =
  let (found, item) = findItem(meta, id)
  if not found:
    return err[DynamicImage](decodingError("heif: primary item not found"))
  if item.typ == "iden":
    # identity: single dimg reference carries the coded image
    for r in meta.refs:
      if r.fromId == id and r.refType == "dimg" and r.toIds.len == 1:
        let inner = decodePrimary(data, meta, r.toIds[0])
        if not inner.ok: return inner
        return applyTransforms(inner.value, itemProps(meta, id))
    return err[DynamicImage](decodingError("heif: bad iden references"))
  if item.typ == "grid" or item.typ == "iovl":
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "heif: derived image '" & item.typ & "' unsupported"))
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
  ## Decode a HEIF/HEIC still (primary item). Still image items only;
  ## sequences, grids/overlays and video bitstreams stay Unsupported.
  if data.len < 12:
    return err[DynamicImage](decodingError("heif: too short"))
  try:
    let meta = parseMeta(data)
    if not meta.hasPrimary:
      return err[DynamicImage](decodingError("heif: missing pitm"))
    decodePrimary(data, meta, meta.primaryId)
  except HeifDecodeError as e:
    err[DynamicImage](decodingError(e.msg))

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
