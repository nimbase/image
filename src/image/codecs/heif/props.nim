## HEIF property interpretation (clean-room): field layouts per
## ISO/IEC 23008-12 (ispe, pixi, irot, imir, clap) and ISO/IEC 23001-17
## (uncC, cmpd, cmpC). Values below were confirmed against bytes emitted by
## real-world writers (see tests/fixtures/heif/), never copied from code.
import ./isobmff

type
  SpatialExtents* = object
    width*, height*: int

  PixInfo* = object
    bits*: seq[int]

  Nclx* = object
    primaries*: int
    transfer*: int
    matrix*: int
    fullRange*: bool

  Rotation* = object
    ## Quarter-turns counter-clockwise (ispe-order application: after decode).
    quarterTurns*: int

  Mirror* = object
    ## See 23008-12 §6.5.12.3: axis 0 exchanges top and bottom, axis 1
    ## exchanges left and right.
    topBottom*: bool
    vertical*: bool

  CleanAperture* = object
    wNum*, wDen*, hNum*, hDen*: int64
    hOffNum*, hOffDen*, vOffNum*, vOffDen*: int64

  UncProfile* = object
    ## Uncompressed frame description (23001-17).
    isV1*: bool
    v1Tag*: string # e.g. "rgb3", "rgba" (v1 only)
    bitDepth*: int # per-component depth (v0: from entries, cross-checked)
    sampling*: int # 0=444/none, 1=422, 2=420 (YUV orders only)
    interleave*: int # 0=component, 1=pixel, 2=mixed, 3=row, 4=tile
    tiled*: bool # nonzero tile-geometry tail bytes (see parseUncC)

  CmpEntry* = object
    compType*: int

proc parseIspe*(payload: seq[uint8]): SpatialExtents =
  if payload.len < 12:
    raise heifErr("heif: truncated ispe")
  let w = (uint32(payload[4]) shl 24) or (uint32(payload[5]) shl 16) or
    (uint32(payload[6]) shl 8) or uint32(payload[7])
  let h = (uint32(payload[8]) shl 24) or (uint32(payload[9]) shl 16) or
    (uint32(payload[10]) shl 8) or uint32(payload[11])
  if w == 0 or h == 0 or w > 16384 or h > 16384:
    raise heifErr("heif: bad ispe dimensions")
  SpatialExtents(width: int(w), height: int(h))

proc parsePixi*(payload: seq[uint8]): PixInfo =
  if payload.len < 5:
    raise heifErr("heif: truncated pixi")
  let n = int(payload[4])
  if payload.len < 5 + n or n == 0 or n > 8:
    raise heifErr("heif: bad pixi count")
  result.bits = newSeq[int](n)
  for i in 0 ..< n:
    result.bits[i] = int(payload[5 + i])
    if result.bits[i] <= 0 or result.bits[i] > 16:
      raise heifErr("heif: bad pixi bit depth")

proc parseNclx*(payload: seq[uint8]): Nclx =
  # colr with colour_type 'nclx': 4CC + u16 primaries + u16 transfer +
  # u8 matrix + u8 full_range_flag<<7. colour_type 'rICC'/'prof' (ICC
  # profile blob) is intentionally not interpreted; decoding proceeds.
  if payload.len < 4:
    raise heifErr("heif: truncated colr")
  if payload[0] != uint8('n') or payload[1] != uint8('c') or
      payload[2] != uint8('l') or payload[3] != uint8('x'):
    raise heifErr("heif: non-nclx colr (ICC profiles not interpreted)")
  if payload.len < 11:
    raise heifErr("heif: truncated nclx")
  Nclx(primaries: (int(payload[4]) shl 8) or int(payload[5]),
    transfer: (int(payload[6]) shl 8) or int(payload[7]),
    matrix: int(payload[8]), fullRange: (payload[9] and 0x80) != 0)

proc parseIrot*(payload: seq[uint8]): Rotation =
  if payload.len < 1:
    raise heifErr("heif: truncated irot")
  Rotation(quarterTurns: int(payload[0] and 3))

proc parseImir*(payload: seq[uint8]): Mirror =
  if payload.len < 1:
    raise heifErr("heif: truncated imir")
  Mirror(topBottom: (payload[0] and 1) == 0)

proc parseClap*(payload: seq[uint8]): CleanAperture =
  if payload.len < 32:
    raise heifErr("heif: truncated clap")
  proc u32o(o: int): int64 =
    (int64(payload[o]) shl 24) or (int64(payload[o + 1]) shl 16) or
      (int64(payload[o + 2]) shl 8) or int64(payload[o + 3])
  proc s32o(o: int): int64 =
    let u = u32o(o)
    if u >= 0x80000000'i64: u - 0x100000000'i64 else: u
  CleanAperture(wNum: u32o(0), wDen: u32o(4), hNum: u32o(8), hDen: u32o(12),
    hOffNum: s32o(16), hOffDen: u32o(20), vOffNum: s32o(24), vOffDen: u32o(28))

proc clapCrop*(clap: CleanAperture, imgW, imgH: int): tuple[x, y, w, h: int] =
  ## Clean-aperture crop in output pixels (23008-12 §6.5.5: centred offsets,
  ## offsets are (width-aperture)/2 style signed fractions).
  if clap.wDen == 0 or clap.hDen == 0 or clap.hOffDen == 0 or
      clap.vOffDen == 0:
    raise heifErr("heif: bad clap denominators")
  let w = int(clap.wNum div clap.wDen)
  let h = int(clap.hNum div clap.hDen)
  if w <= 0 or h <= 0 or w > imgW or h > imgH:
    raise heifErr("heif: clap aperture out of range")
  let cx = imgW div 2 + int(clap.hOffNum div clap.hOffDen)
  let cy = imgH div 2 + int(clap.vOffNum div clap.vOffDen)
  let x = max(0, cx - w div 2)
  let y = max(0, cy - h div 2)
  (min(x, imgW - w), min(y, imgH - h), w, h)

proc parseCmpd*(payload: seq[uint8]): seq[CmpEntry] =
  # cmpd: entry_count u32 + u16 component types. Observed types: 1 = mono/Y,
  # 2 = Cb, 3 = Cr, 4 = R, 5 = G, 6 = B, 7 = alpha (23001-17 Table 1).
  if payload.len < 4:
    raise heifErr("heif: truncated cmpd")
  let n = (uint32(payload[0]) shl 24) or (uint32(payload[1]) shl 16) or
    (uint32(payload[2]) shl 8) or uint32(payload[3])
  if n == 0 or n > 8 or payload.len < 4 + 2 * int(n):
    raise heifErr("heif: bad cmpd count")
  for i in 0 ..< int(n):
    let t = (int(payload[4 + 2 * i]) shl 8) or int(payload[5 + 2 * i])
    result.add(CmpEntry(compType: t))

proc parseUncC*(payload: seq[uint8]): UncProfile =
  # uncC FullBox. v1 (8 payload bytes): version=1 + profile fourcc
  # ("rgb3", "rgba", …); v0: component count + 5-byte entries + sampling +
  # interleave + tail (observably zero when untiled).
  if payload.len < 8:
    raise heifErr("heif: truncated uncC")
  let v = payload[0]
  if v == 1:
    if payload.len < 8:
      raise heifErr("heif: truncated uncC v1")
    var tag = ""
    for i in 4 ..< 8: tag.add(char(payload[i]))
    return UncProfile(isV1: true, v1Tag: tag, tiled: false)
  elif v == 0:
    if payload.len < 12:
      raise heifErr("heif: truncated uncC v0")
    let n = (uint32(payload[8]) shl 24) or (uint32(payload[9]) shl 16) or
      (uint32(payload[10]) shl 8) or uint32(payload[11])
    if n == 0 or n > 8 or payload.len < 12 + 5 * int(n) + 2:
      raise heifErr("heif: bad uncC v0 count")
    var depth = -1
    for i in 0 ..< int(n):
      let base = 12 + 5 * i
      if payload[base] != 0 or payload[base + 3] != 0 or
          payload[base + 4] != 0:
        raise heifErr("heif: unsupported uncC v0 entry flags")
      let d = int(payload[base + 2]) + 1
      if d != 8 and d != 16:
        # 10/12-bit have no validation fixtures; fail cleanly instead of
        # guessing (23001-17 allows them, pure-Nim v1 does not emit them).
        raise heifErr("heif: unsupported uncompressed bit depth")
      if depth == -1: depth = d
      elif depth != d:
        raise heifErr("heif: mixed uncompressed bit depths unsupported")
    let sampling = int(payload[12 + 5 * int(n)])
    let interleave = int(payload[13 + 5 * int(n)])
    if sampling < 0 or sampling > 2:
      raise heifErr("heif: bad uncompressed sampling")
    if interleave < 0 or interleave > 4:
      raise heifErr("heif: unsupported uncompressed interleave")
    # Tiled/complex layouts (23001-17 block/tile fields) show up as nonzero
    # tail bytes. Offset 18+5n separates cleanly on 80 observed files: the
    # only benign nonzero byte (a 0x80 emitted for mono frames) sits below
    # it. Anything at/above is tile geometry until proven otherwise.
    var tiled = false
    for i in 18 + 5 * int(n) ..< payload.len:
      if payload[i] != 0:
        tiled = true
        break
    return UncProfile(isV1: false, bitDepth: depth, sampling: sampling,
      interleave: interleave, tiled: tiled)
  else:
    raise heifErr("heif: unsupported uncC version")

proc parseCmpC*(payload: seq[uint8]): string =
  # cmpC FullBox v0 + 4-char compressor id ("zlib", "defl", …) + params.
  # Only the id is interpreted; payload shape validated loosely.
  if payload.len < 9:
    raise heifErr("heif: truncated cmpC")
  var id = ""
  for i in 4 ..< 8: id.add(char(payload[i]))
  id

# --- Additional descriptive properties (reader) ---

type
  PixelAspect* = object
    hSpacing*, vSpacing*: uint32
  AuxType* = object
    auxType*: string
  RelLoc* = object
    hOff*, vOff*: uint32
  LayerSel* = object
    layerId*: uint16
  UserDesc* = object
    lang*, name*, desc*, tags*: string

proc parsePasp*(payload: seq[uint8]): PixelAspect =
  if payload.len < 8:
    raise heifErr("heif: truncated pasp")
  PixelAspect(
    hSpacing: (uint32(payload[0]) shl 24) or (uint32(payload[1]) shl 16) or
      (uint32(payload[2]) shl 8) or uint32(payload[3]),
    vSpacing: (uint32(payload[4]) shl 24) or (uint32(payload[5]) shl 16) or
      (uint32(payload[6]) shl 8) or uint32(payload[7]))

proc parseAuxC*(payload: seq[uint8]): AuxType =
  if payload.len < 5: raise heifErr("heif: truncated auxC")
  var s = ""
  var i = 4
  while i < payload.len and payload[i] != 0:
    s.add(char(payload[i])); inc(i)
  if i >= payload.len: raise heifErr("heif: bad auxC string")
  AuxType(auxType: s)

proc parseRloc*(payload: seq[uint8]): RelLoc =
  if payload.len < 12: raise heifErr("heif: truncated rloc")
  RelLoc(
    hOff: (uint32(payload[4]) shl 24) or (uint32(payload[5]) shl 16) or
      (uint32(payload[6]) shl 8) or uint32(payload[7]),
    vOff: (uint32(payload[8]) shl 24) or (uint32(payload[9]) shl 16) or
      (uint32(payload[10]) shl 8) or uint32(payload[11]))

proc parseLsel*(payload: seq[uint8]): LayerSel =
  if payload.len < 2: raise heifErr("heif: truncated lsel")
  LayerSel(layerId: (uint16(payload[0]) shl 8) or uint16(payload[1]))

type
  ScaleInfo* = object
    wNum*, wDen*, hNum*, hDen*: uint16

proc parseIscl*(payload: seq[uint8]): ScaleInfo =
  if payload.len < 12: raise heifErr("heif: truncated iscl")
  proc u16o(o: int): uint16 =
    (uint16(payload[o]) shl 8) or uint16(payload[o+1])
  ScaleInfo(wNum: u16o(4), wDen: u16o(6), hNum: u16o(8), hDen: u16o(10))

proc readUtf8Str(payload: seq[uint8], pos: var int): string =
  result = ""
  while pos < payload.len and payload[pos] != 0:
    result.add(char(payload[pos])); inc(pos)
  if pos >= payload.len: raise heifErr("heif: bad utf8 string")
  inc(pos) # skip NUL

proc parseUdes*(payload: seq[uint8]): UserDesc =
  if payload.len < 5: raise heifErr("heif: truncated udes")
  var pos = 4
  let lang = readUtf8Str(payload, pos)
  let name = readUtf8Str(payload, pos)
  let desc = readUtf8Str(payload, pos)
  let tags = readUtf8Str(payload, pos)
  UserDesc(lang: lang, name: name, desc: desc, tags: tags)

proc parseAltt*(payload: seq[uint8]): UserDesc =
  if payload.len < 5: raise heifErr("heif: truncated altt")
  var pos = 4
  let text = readUtf8Str(payload, pos)
  let lang = readUtf8Str(payload, pos)
  UserDesc(lang: lang, name: text, desc: "", tags: "")

# --- Property builders (writer) ---
# Each returns the full property payload as stored in ipco
# (including FullBox header where applicable).

proc buildIspe*(w, h: uint32): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  result.putU32BE(w)
  result.putU32BE(h)

proc buildPixi*(bits: openArray[int]): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  result.add(uint8(bits.len))
  for b in bits: result.add(uint8(b))

proc buildNclx*(primaries, transfer: uint16, matrix: uint8,
    fullRange: bool): seq[uint8] =
  result = @[]
  result.put4CC("nclx")
  result.putU16BE(primaries)
  result.putU16BE(transfer)
  result.add(matrix)
  result.add(if fullRange: 0x80'u8 else: 0x00'u8)
  result.add(0); result.add(0); result.add(0)

proc buildIrot*(turns: int): seq[uint8] =
  @[uint8(turns and 3)]

proc buildImir*(topBottom: bool): seq[uint8] =
  @[if topBottom: 0'u8 else: 1'u8]

proc buildClap*(wNum, wDen, hNum, hDen: uint32, hOff, vOff: int32): seq[uint8] =
  result = @[]
  result.putU32BE(wNum); result.putU32BE(wDen)
  result.putU32BE(hNum); result.putU32BE(hDen)
  result.putU32BE(cast[uint32](hOff)); result.putU32BE(wDen)
  result.putU32BE(cast[uint32](vOff)); result.putU32BE(hDen)

proc buildPasp*(h, v: uint32): seq[uint8] =
  result = @[]
  result.putU32BE(h); result.putU32BE(v)

proc buildAuxC*(uri: string): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  for c in uri: result.add(uint8(c))
  result.add(0)

proc buildRloc*(h, v: uint32): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  result.putU32BE(h); result.putU32BE(v)

proc buildIscl*(wNum, wDen, hNum, hDen: uint16): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  result.putU16BE(wNum); result.putU16BE(wDen)
  result.putU16BE(hNum); result.putU16BE(hDen)

proc putUtf8Str(dst: var seq[uint8], s: string) =
  for c in s: dst.add(uint8(c))
  dst.add(0)

proc buildUdes*(lang, name, desc, tags: string): seq[uint8] =
  result = @[]
  result.putFullHeader(0, 0)
  result.putUtf8Str(lang); result.putUtf8Str(name)
  result.putUtf8Str(desc); result.putUtf8Str(tags)

proc buildUncCV1*(tag: string): seq[uint8] =
  result = @[]
  result.putFullHeader(1, 0)
  result.put4CC(tag)

proc buildUncCV0*(depth: int, sampling, interleave: int,
    compTypes: openArray[int]): seq[uint8] =
  ## v0 layout matching observed real-writer bytes (see parseUncC):
  ## FullBox + zero word + count + 5-byte entries [0, index, depth-1, 0, 0]
  ## + sampling + interleave + zero word. No tail means untiled.
  result = @[]
  result.putFullHeader(0, 0)
  result.putU32BE(0) # zero word before count (always 0 observed)
  result.putU32BE(uint32(compTypes.len))
  for i in 0 ..< compTypes.len:
    result.add(0) # flags
    result.add(uint8(i)) # component index (0-based position)
    result.add(uint8(depth - 1))
    result.add(0); result.add(0)
  result.add(uint8(sampling))
  result.add(uint8(interleave))
  result.putU32BE(0) # zero word after interleave (always 0 observed)

proc buildCmpd*(compTypes: openArray[int]): seq[uint8] =
  result = @[]
  result.putU32BE(uint32(compTypes.len))
  for t in compTypes: result.putU16BE(uint16(t))
