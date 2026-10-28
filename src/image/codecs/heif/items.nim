## HEIF item layer (clean-room): `meta`-box parse per ISO/IEC 23008-12.
## Covers ftyp brands, pitm, iloc (v0/v1/v2), iinf/infe (v2/v3), iprp
## (ipco raw properties + ipma v0/v1 associations), iref, idat location.
## Only boxes real writers emit are interpreted; anything else is skipped.
import ./isobmff
import ../../error

type
  HeifItem* = object
    id*: uint32
    typ*: string
    hidden*: bool

  ItemExtent* = object
    ## Absolute file offset + length of one data run.
    offset*: int
    length*: int

  RawProperty* = object
    kind*: string
    payload*: seq[uint8]
    essential*: bool

  HeifRef* = object
    fromId*: uint32
    refType*: string
    toIds*: seq[uint32]

  HeifMeta* = object
    majorBrand*: string
    compatBrands*: seq[string]
    items*: seq[HeifItem]
    primaryId*: uint32
    hasPrimary*: bool
    extents*: seq[tuple[id: uint32, runs: seq[ItemExtent]]]
    props*: seq[tuple[id: uint32, props: seq[RawProperty]]]
    refs*: seq[HeifRef]
    idatOff*: int
    idatLen*: int
    hasIdat*: bool

proc payload*(data: seq[uint8], b: Box): seq[uint8] =
  checkRange(data, b.payloadOff, b.payloadLen, b.typStr())
  data[b.payloadOff ..< b.payloadOff + b.payloadLen]

proc parseFtyp(data: seq[uint8], b: Box,
    meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 8:
    raise heifErr("heif: truncated ftyp")
  meta.majorBrand = ""
  for i in 0 ..< 4: meta.majorBrand.add(char(p[i]))
  var off = 8
  while off + 4 <= p.len:
    var s = ""
    for i in 0 ..< 4: s.add(char(p[off + i]))
    meta.compatBrands.add(s)
    off += 4

const HeifBrands = ["mif1", "mif2", "msf1", "mif3", "heic", "heix", "hevc",
  "hevx", "vvic", "vvis", "avic", "avis", "jpeg", "j2ki", "unci", "miaf",
  "miff", "1pic", "pred"]

proc isHeifBrand*(s: string): bool =
  for b in HeifBrands:
    if s == b: return true
  false

proc parsePitm(data: seq[uint8], b: Box, meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 4:
    raise heifErr("heif: truncated pitm")
  let v = p[0]
  if v == 0:
    if p.len < 6: raise heifErr("heif: truncated pitm")
    meta.primaryId = (uint32(p[4]) shl 8) or uint32(p[5])
  else:
    if p.len < 8: raise heifErr("heif: truncated pitm")
    meta.primaryId = (uint32(p[4]) shl 24) or (uint32(p[5]) shl 16) or
      (uint32(p[6]) shl 8) or uint32(p[7])
  meta.hasPrimary = true

proc parseInfe(data: seq[uint8], b: Box, meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 4:
    raise heifErr("heif: truncated infe")
  let v = p[0]
  let flags = (uint32(p[1]) shl 16) or (uint32(p[2]) shl 8) or uint32(p[3])
  var item = HeifItem(hidden: (flags and 1) != 0)
  var off = 4
  if v == 2 or v == 3:
    let idLen = if v == 2: 2 else: 4
    if p.len < off + 2 * idLen + 4:
      raise heifErr("heif: truncated infe")
    var id: uint32 = 0
    for i in 0 ..< idLen: id = (id shl 8) or uint32(p[off + i])
    off += idLen
    off += idLen # item_protection_index
    item.id = id
    item.typ = ""
    for i in 0 ..< 4: item.typ.add(char(p[off + i]))
    off += 4
    meta.items.add(item)
  else:
    raise heifErr("heif: unsupported infe version (only v2/v3)")

proc parseIinf(data: seq[uint8], b: Box, meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 4:
    raise heifErr("heif: truncated iinf")
  let v = p[0]
  var count: uint32
  var body: seq[Box]
  # entry_count lives right after version/flags; children after it.
  var tmp = b
  if v == 0:
    if p.len < 6: raise heifErr("heif: truncated iinf")
    count = (uint32(p[4]) shl 8) or uint32(p[5])
    tmp.payloadOff = b.payloadOff + 6
    tmp.payloadLen = b.payloadLen - 6
  else:
    if p.len < 8: raise heifErr("heif: truncated iinf")
    count = (uint32(p[4]) shl 24) or (uint32(p[5]) shl 16) or
      (uint32(p[6]) shl 8) or uint32(p[7])
    tmp.payloadOff = b.payloadOff + 8
    tmp.payloadLen = b.payloadLen - 8
  body = childBoxes(data, tmp)
  var n = 0'u32
  for c in body:
    if c.isTypeStr("infe"):
      parseInfe(data, c, meta)
      inc(n)
  if n != count:
    raise heifErr("heif: iinf entry count mismatch")

proc readSized(data: seq[uint8], p: seq[uint8], off: int, nbytes: int,
    what: string): uint64 =
  if nbytes == 0: return 0
  if nbytes != 4 and nbytes != 8:
    raise heifErr("heif: bad " & what & " size")
  if off + nbytes > p.len:
    raise heifErr("heif: truncated iloc")
  discard data
  if nbytes == 4:
    (uint64(p[off]) shl 24) or (uint64(p[off + 1]) shl 16) or
      (uint64(p[off + 2]) shl 8) or uint64(p[off + 3])
  else:
    (uint64(p[off]) shl 56) or (uint64(p[off + 1]) shl 48) or
      (uint64(p[off + 2]) shl 40) or (uint64(p[off + 3]) shl 32) or
      (uint64(p[off + 4]) shl 24) or (uint64(p[off + 5]) shl 16) or
      (uint64(p[off + 6]) shl 8) or uint64(p[off + 7])

proc parseIloc(data: seq[uint8], b: Box, meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 8:
    raise heifErr("heif: truncated iloc")
  let v = p[0]
  if v > 2:
    raise heifErr("heif: unsupported iloc version")
  let offSize = int((p[4] shr 4) and 0xF)
  let lenSize = int(p[4] and 0xF)
  let baseSize = int((p[5] shr 4) and 0xF)
  let idxSize = if v >= 1: int(p[5] and 0xF) else: 0
  var off = 6
  var count: uint32
  if v < 2:
    if p.len < 8: raise heifErr("heif: truncated iloc")
    count = (uint32(p[6]) shl 8) or uint32(p[7])
    off = 8
  else:
    if p.len < 10: raise heifErr("heif: truncated iloc")
    count = (uint32(p[6]) shl 24) or (uint32(p[7]) shl 16) or
      (uint32(p[8]) shl 8) or uint32(p[9])
    off = 10
  let idLen = if v < 1: 2 else: 4
  for _ in 0 ..< count:
    if off + idLen + 2 > p.len:
      raise heifErr("heif: truncated iloc item")
    var id: uint32 = 0
    for i in 0 ..< idLen: id = (id shl 8) or uint32(p[off + i])
    off += idLen
    var construction = 0
    if v >= 1:
      construction = int(p[off])
      inc(off)
    off += 2 # data_reference_index
    let base = readSized(data, p, off, baseSize, "base_offset")
    off += baseSize
    var extCount: uint32
    if v < 2:
      if off + 2 > p.len: raise heifErr("heif: truncated iloc")
      extCount = (uint32(p[off]) shl 8) or uint32(p[off + 1])
      off += 2
    else:
      if off + 4 > p.len: raise heifErr("heif: truncated iloc")
      extCount = (uint32(p[off]) shl 24) or (uint32(p[off + 1]) shl 16) or
        (uint32(p[off + 2]) shl 8) or uint32(p[off + 3])
      off += 4
    var runs: seq[ItemExtent] = @[]
    for _ in 0 ..< extCount:
      if idxSize > 0:
        off += idxSize # extent_index (order within item, ignored)
      let eoff = readSized(data, p, off, offSize, "extent_offset")
      off += offSize
      let elen = readSized(data, p, off, lenSize, "extent_length")
      off += lenSize
      if construction == 0:
        let abs = base + eoff
        if abs + elen > uint64(high(int)):
          raise heifErr("heif: iloc extent overflow")
        runs.add(ItemExtent(offset: int(abs), length: int(elen)))
      elif construction == 1:
        if not meta.hasIdat:
          raise heifErr("heif: idat construction without idat box")
        let abs = uint64(meta.idatOff) + base + eoff
        if abs + elen > uint64(high(int)):
          raise heifErr("heif: iloc extent overflow")
        runs.add(ItemExtent(offset: int(abs), length: int(elen)))
      else:
        raise heifErr(
          "heif: unsupported iloc construction_method (item offsets)")
    meta.extents.add((id, runs))

proc parseIpma(data: seq[uint8], b: Box, ipco: seq[Box],
    meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 8:
    raise heifErr("heif: truncated ipma")
  let v = p[0]
  let flags = (uint32(p[1]) shl 16) or (uint32(p[2]) shl 8) or uint32(p[3])
  if p.len < 8: raise heifErr("heif: truncated ipma")
  let entryCount = (uint32(p[4]) shl 24) or (uint32(p[5]) shl 16) or
    (uint32(p[6]) shl 8) or uint32(p[7])
  var off = 8
  let idLen = if v < 1: 2 else: 4
  let wide = (flags and 1) != 0
  for _ in 0 ..< entryCount:
    if off + idLen + 1 > p.len:
      raise heifErr("heif: truncated ipma")
    var id: uint32 = 0
    for i in 0 ..< idLen: id = (id shl 8) or uint32(p[off + i])
    off += idLen
    let assocCount = int(p[off])
    inc(off)
    var props: seq[RawProperty] = @[]
    for _ in 0 ..< assocCount:
      var essential = false
      var index = 0
      if wide:
        if off + 2 > p.len: raise heifErr("heif: truncated ipma")
        let w = (uint16(p[off]) shl 8) or uint16(p[off + 1])
        off += 2
        essential = (w and 0x8000'u16) != 0
        index = int(w and 0x7FFF'u16)
      else:
        if off + 1 > p.len: raise heifErr("heif: truncated ipma")
        let x = p[off]
        inc(off)
        essential = (x and 0x80) != 0
        index = int(x and 0x7F)
      if index < 1 or index > ipco.len:
        raise heifErr("heif: ipma property index out of range")
      let pb = ipco[index - 1]
      props.add(RawProperty(kind: pb.typStr(), payload: payload(data, pb),
        essential: essential))
    meta.props.add((id, props))

proc parseIref(data: seq[uint8], b: Box, meta: var HeifMeta) =
  let p = payload(data, b)
  if p.len < 4:
    raise heifErr("heif: truncated iref")
  let v = p[0]
  if v > 1:
    raise heifErr("heif: unsupported iref version")
  var off = 4
  let idLen = if v == 0: 2 else: 4
  while off + 8 <= p.len:
    let rs = (uint32(p[off]) shl 24) or (uint32(p[off + 1]) shl 16) or
      (uint32(p[off + 2]) shl 8) or uint32(p[off + 3])
    if rs < 8 or off + int(rs) > p.len:
      raise heifErr("heif: bad iref entry")
    var rt = ""
    for i in 4 ..< 8: rt.add(char(p[off + i]))
    var q = off + 8
    if q + idLen + (if v == 0: 2 else: 4) > off + int(rs):
      raise heifErr("heif: truncated iref entry")
    var fromId: uint32 = 0
    for i in 0 ..< idLen: fromId = (fromId shl 8) or uint32(p[q + i])
    q += idLen
    var nref: uint32
    if v == 0:
      nref = (uint32(p[q]) shl 8) or uint32(p[q + 1])
      q += 2
    else:
      nref = (uint32(p[q]) shl 24) or (uint32(p[q + 1]) shl 16) or
        (uint32(p[q + 2]) shl 8) or uint32(p[q + 3])
      q += 4
    var toIds: seq[uint32] = @[]
    for _ in 0 ..< nref:
      if q + idLen > off + int(rs):
        raise heifErr("heif: truncated iref entry")
      var t: uint32 = 0
      for i in 0 ..< idLen: t = (t shl 8) or uint32(p[q + i])
      q += idLen
      toIds.add(t)
    meta.refs.add(HeifRef(fromId: fromId, refType: rt, toIds: toIds))
    off += int(rs)

proc parseMeta*(data: seq[uint8]): HeifMeta =
  ## Parse top-level boxes: ftyp + first meta. Raises HeifDecodeError.
  result = HeifMeta()
  var foundFtyp = false
  var foundMeta = false
  for b in topLevelBoxes(data):
    if b.isTypeStr("ftyp") and not foundFtyp:
      parseFtyp(data, b, result)
      foundFtyp = true
    elif b.isTypeStr("meta") and not foundMeta:
      foundMeta = true
      for c in childBoxes(data, b, 4):
        if c.isTypeStr("pitm"):
          parsePitm(data, c, result)
        elif c.isTypeStr("iloc"):
          parseIloc(data, c, result)
        elif c.isTypeStr("iinf"):
          parseIinf(data, c, result)
        elif c.isTypeStr("iprp"):
          var ipco: seq[Box] = @[]
          var ipma: seq[Box] = @[]
          for g in childBoxes(data, c):
            if g.isTypeStr("ipco"): ipco = childBoxes(data, g)
            elif g.isTypeStr("ipma"): ipma.add(g)
          for m in ipma: parseIpma(data, m, ipco, result)
        elif c.isTypeStr("iref"):
          parseIref(data, c, result)
        elif c.isTypeStr("idat") and not result.hasIdat:
          result.hasIdat = true
          result.idatOff = c.payloadOff
          result.idatLen = c.payloadLen
        # hdlr and anything else: intentionally skipped
  if not foundFtyp:
    raise heifErr("heif: missing ftyp box")
  if not foundMeta:
    raise heifErr("heif: missing meta box")
  if not isHeifBrand(result.majorBrand):
    raise heifErr("heif: not a HEIF brand (" & result.majorBrand & ")")

proc findItem*(meta: HeifMeta, id: uint32): tuple[found: bool, item: HeifItem] =
  for it in meta.items:
    if it.id == id: return (true, it)
  (false, HeifItem())

proc itemBytes*(data: seq[uint8], meta: HeifMeta,
    id: uint32): seq[uint8] =
  ## Concatenate an item's extents. Bounds-checked; raises HeifDecodeError.
  result = @[]
  var found = false
  for (eid, runs) in meta.extents:
    if eid == id:
      found = true
      for r in runs:
        checkRange(data, r.offset, r.length, "item data")
        result.add(data[r.offset ..< r.offset + r.length])
  if not found:
    raise heifErr("heif: item has no iloc extents")

proc itemProps*(meta: HeifMeta, id: uint32): seq[RawProperty] =
  for (eid, props) in meta.props:
    if eid == id: return props
  @[]
