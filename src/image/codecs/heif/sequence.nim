## Timed image sequences (clean-room, MIT).
## Parses ISOBMFF `moov` with `pict` tracks (sample tables) plus fragmented
## `moof`/`traf`/`trun` (merged into tracks by tfhd track_ID) and builds
## matching non-fragmented files. Uncompressed v0/v1 and JPEG samples are
## decoded; video bitstreams stay Unsupported (passthrough).
## Layout is our own minimal profile: visual sample entries with a 78-byte
## header (width/height at payload offsets 24/26) followed by codec boxes
## (`uncC` etc.). Real-world files with the same header shape decode;
## anything else fails cleanly.
import ./isobmff
import ../../error

type
  HeifSample* = object
    offset*: int ## absolute file offset
    size*: int
    duration*: uint32
    isSync*: bool

  HeifTrack* = object
    trackId*: uint32
    handler*: string ## e.g. "pict"
    coding*: string ## sample entry 4CC, e.g. "unci", "jpeg", "hvc1"
    width*, height*: int
    timescale*: uint32
    duration*: uint64
    samples*: seq[HeifSample]
    uncC*: seq[uint8] ## raw property payload incl. FullBox header
    cmpd*: seq[uint8]
    pixiBits*: seq[int]

  HeifMovie* = object
    timescale*: uint32
    duration*: uint64
    tracks*: seq[HeifTrack]
    hasMoof*: bool

proc rdU16(p: seq[uint8], o: int): uint16 =
  (uint16(p[o]) shl 8) or uint16(p[o+1])

proc rdU32(p: seq[uint8], o: int): uint32 =
  (uint32(p[o]) shl 24) or (uint32(p[o+1]) shl 16) or
    (uint32(p[o+2]) shl 8) or uint32(p[o+3])

proc rdU64(p: seq[uint8], o: int): uint64 =
  (uint64(p[o]) shl 56) or (uint64(p[o+1]) shl 48) or
    (uint64(p[o+2]) shl 40) or (uint64(p[o+3]) shl 32) or
    (uint64(p[o+4]) shl 24) or (uint64(p[o+5]) shl 16) or
    (uint64(p[o+6]) shl 8) or uint64(p[o+7])

proc boxPayload(data: seq[uint8], b: Box): seq[uint8] =
  checkRange(data, b.payloadOff, b.payloadLen, b.typStr())
  data[b.payloadOff ..< b.payloadOff + b.payloadLen]

proc parseMvhd(data: seq[uint8], b: Box, mvTs: var uint32,
    mvDur: var uint64) =
  let p = boxPayload(data, b)
  if p.len < 4: raise heifErr("heif: truncated mvhd")
  let v = p[0]
  if v == 0:
    if p.len < 24: raise heifErr("heif: truncated mvhd")
    mvTs = rdU32(p, 12)
    mvDur = rdU32(p, 20)
  else:
    if p.len < 32: raise heifErr("heif: truncated mvhd")
    mvTs = rdU32(p, 20)
    mvDur = rdU64(p, 24)

proc parseMdhd(data: seq[uint8], b: Box, ts: var uint32,
    dur: var uint64) =
  let p = boxPayload(data, b)
  if p.len < 4: raise heifErr("heif: truncated mdhd")
  let v = p[0]
  if v == 0:
    if p.len < 24: raise heifErr("heif: truncated mdhd")
    ts = rdU32(p, 12)
    dur = rdU32(p, 20)
  else:
    if p.len < 32: raise heifErr("heif: truncated mdhd")
    ts = rdU32(p, 20)
    dur = rdU64(p, 24)

proc parseHdlr(data: seq[uint8], b: Box): string =
  let p = boxPayload(data, b)
  if p.len < 12: raise heifErr("heif: truncated hdlr")
  result = ""
  for i in 8 ..< 12: result.add(char(p[i]))

proc parseStsdEntry(data: seq[uint8], e: Box, coding: var string,
    w, h: var int, uncC, cmpd: var seq[uint8], pixi: var seq[int]) =
  coding = e.typStr()
  let p = boxPayload(data, e)
  w = 0; h = 0
  uncC = @[]; cmpd = @[]; pixi = @[]
  if p.len >= 28:
    w = int(rdU16(p, 24))
    h = int(rdU16(p, 26))
  if p.len > 78:
    # Child codec boxes after the 78-byte visual header.
    var off = e.payloadOff + 78
    let stop = e.payloadOff + e.payloadLen
    while off + 8 <= stop:
      let c = readBoxAt(data, off)
      if off + c.boxLen > stop: break
      if c.isTypeStr("uncC"):
        uncC = boxPayload(data, c)
      elif c.isTypeStr("cmpd"):
        cmpd = boxPayload(data, c)
      elif c.isTypeStr("pixi"):
        let pp = boxPayload(data, c)
        if pp.len >= 5:
          let n = int(pp[4])
          if n > 0 and n <= 8 and pp.len >= 5 + n:
            pixi = @[]
            for i in 0 ..< n: pixi.add(int(pp[5 + i]))
      off += c.boxLen

proc parseStsd(data: seq[uint8], b: Box, coding: var string,
    w, h: var int, uncC, cmpd: var seq[uint8], pixi: var seq[int]) =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated stsd")
  let cnt = rdU32(p, 4)
  if cnt == 0 or cnt > 16: raise heifErr("heif: bad stsd count")
  var tmp = b
  tmp.payloadOff = b.payloadOff + 8
  tmp.payloadLen = b.payloadLen - 8
  let entries = childBoxes(data, tmp)
  if entries.len == 0: raise heifErr("heif: empty stsd")
  # First entry defines the track coding for v1.
  parseStsdEntry(data, entries[0], coding, w, h, uncC, cmpd, pixi)

proc parseStts(data: seq[uint8], b: Box): seq[tuple[n: uint32, d: uint32]] =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated stts")
  let cnt = rdU32(p, 4)
  if cnt > 100000: raise heifErr("heif: bad stts count")
  if p.len < 8 + 8 * int(cnt): raise heifErr("heif: truncated stts")
  for i in 0 ..< int(cnt):
    result.add((rdU32(p, 8 + 8*i), rdU32(p, 12 + 8*i)))

proc parseStsc(data: seq[uint8], b: Box): seq[tuple[first, per, desc: uint32]] =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated stsc")
  let cnt = rdU32(p, 4)
  if cnt == 0 or cnt > 100000: raise heifErr("heif: bad stsc count")
  if p.len < 8 + 12 * int(cnt): raise heifErr("heif: truncated stsc")
  for i in 0 ..< int(cnt):
    result.add((rdU32(p, 8+12*i), rdU32(p, 12+12*i), rdU32(p, 16+12*i)))

proc parseStsz(data: seq[uint8], b: Box): tuple[uniform: uint32,
    sizes: seq[uint32]] =
  let p = boxPayload(data, b)
  if p.len < 12: raise heifErr("heif: truncated stsz")
  let u = rdU32(p, 4)
  let n = rdU32(p, 8)
  if n > 100000: raise heifErr("heif: bad stsz count")
  if u != 0:
    return (u, @[])
  if p.len < 12 + 4 * int(n): raise heifErr("heif: truncated stsz")
  var s: seq[uint32] = @[]
  for i in 0 ..< int(n): s.add(rdU32(p, 12 + 4*i))
  (0, s)

proc parseStco(data: seq[uint8], b: Box, wide: bool): seq[uint64] =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated stco")
  let n = rdU32(p, 4)
  if n > 100000: raise heifErr("heif: bad chunk count")
  if wide:
    if p.len < 8 + 8 * int(n): raise heifErr("heif: truncated co64")
    for i in 0 ..< int(n): result.add(rdU64(p, 8 + 8*i))
  else:
    if p.len < 8 + 4 * int(n): raise heifErr("heif: truncated stco")
    for i in 0 ..< int(n): result.add(uint64(rdU32(p, 8 + 4*i)))

proc parseStss(data: seq[uint8], b: Box): seq[uint32] =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated stss")
  let n = rdU32(p, 4)
  if n > 100000: raise heifErr("heif: bad stss count")
  if p.len < 8 + 4 * int(n): raise heifErr("heif: truncated stss")
  for i in 0 ..< int(n): result.add(rdU32(p, 8 + 4*i))

proc parseTrak(data: seq[uint8], trak: Box): HeifTrack =
  result = HeifTrack()
  var mdhdTs: uint32 = 0
  var mdhdDur: uint64 = 0
  var hdlr = ""
  var stsdCoding = ""
  var stsdW, stsdH = 0
  var stsdUncC, stsdCmpd: seq[uint8] = @[]
  var stsdPixi: seq[int] = @[]
  var stts: seq[tuple[n: uint32, d: uint32]] = @[]
  var stsc: seq[tuple[first, per, desc: uint32]] = @[]
  var stszU: uint32 = 0
  var stszSizes: seq[uint32] = @[]
  var chunks: seq[uint64] = @[]
  var syncs: seq[uint32] = @[]
  var hasStss = false
  var trackId: uint32 = 0
  for c in childBoxes(data, trak):
    if c.isTypeStr("tkhd"):
      let p = boxPayload(data, c)
      if p.len >= 4:
        let v = p[0]
        if v == 0 and p.len >= 24:
          trackId = rdU32(p, 12)
        elif v != 0 and p.len >= 32:
          trackId = rdU32(p, 20)
    elif c.isTypeStr("mdia"):
      for m in childBoxes(data, c):
        if m.isTypeStr("mdhd"):
          parseMdhd(data, m, mdhdTs, mdhdDur)
        elif m.isTypeStr("hdlr"):
          hdlr = parseHdlr(data, m)
        elif m.isTypeStr("minf"):
          for mi in childBoxes(data, m):
            if mi.isTypeStr("stbl"):
              for s in childBoxes(data, mi):
                if s.isTypeStr("stsd"):
                  parseStsd(data, s, stsdCoding, stsdW, stsdH,
                    stsdUncC, stsdCmpd, stsdPixi)
                elif s.isTypeStr("stts"):
                  stts = parseStts(data, s)
                elif s.isTypeStr("stsc"):
                  stsc = parseStsc(data, s)
                elif s.isTypeStr("stsz"):
                  (stszU, stszSizes) = parseStsz(data, s)
                elif s.isTypeStr("stco"):
                  chunks = parseStco(data, s, false)
                elif s.isTypeStr("co64"):
                  chunks = parseStco(data, s, true)
                elif s.isTypeStr("stss"):
                  syncs = parseStss(data, s)
                  hasStss = true
  if hdlr == "" or stsdCoding == "":
    raise heifErr("heif: bad pict track")
  result.trackId = trackId
  result.handler = hdlr
  result.coding = stsdCoding
  result.width = stsdW
  result.height = stsdH
  result.timescale = mdhdTs
  result.duration = mdhdDur
  result.uncC = stsdUncC
  result.cmpd = stsdCmpd
  result.pixiBits = stsdPixi
  # Sample count from stsz.
  var count = 0
  if stszU != 0:
    # Uniform size: count must come from stts totals or chunks; use stts sum.
    var tot = 0
    for e in stts: tot += int(e.n)
    if tot > 100000: raise heifErr("heif: bad sequence length")
    count = tot
  else:
    count = stszSizes.len
  if count > 100000: raise heifErr("heif: bad sequence length")
  if count == 0:
    # No moov samples: valid for fragmented files (samples arrive via
    # moof). Durations and chunk tables are irrelevant here.
    return
  if chunks.len == 0 or stsc.len == 0:
    raise heifErr("heif: missing chunk table")
  # Expand sample-to-chunk: per-chunk sample counts.
  var perChunk = newSeq[int](chunks.len)
  for si in 0 ..< stsc.len:
    let first = int(stsc[si].first) # 1-based
    let per = int(stsc[si].per)
    if first < 1 or first > chunks.len or per <= 0 or per > 100000:
      raise heifErr("heif: bad stsc")
    let last = if si + 1 < stsc.len: int(stsc[si+1].first) - 1
      else: chunks.len
    if last < first: raise heifErr("heif: bad stsc range")
    for ci in first .. last:
      perChunk[ci - 1] = per
  # Walk chunks to assign offsets.
  var sizes = newSeq[int](count)
  if stszU != 0:
    for i in 0 ..< count: sizes[i] = int(stszU)
  else:
    for i in 0 ..< count: sizes[i] = int(stszSizes[i])
  var offs = newSeq[int](count)
  var si = 0
  for ci in 0 ..< chunks.len:
    let base = int(chunks[ci])
    var cur = base
    for k in 0 ..< perChunk[ci]:
      if si >= count: break
      if sizes[si] <= 0 or sizes[si] > 64*1024*1024:
        raise heifErr("heif: bad sample size")
      offs[si] = cur
      cur += sizes[si]
      inc(si)
  if si != count:
    raise heifErr("heif: chunk/sample mismatch")
  # Durations from stts.
  var durs = newSeq[uint32](count)
  var di = 0
  for e in stts:
    for k in 0 ..< int(e.n):
      if di >= count: break
      durs[di] = e.d
      inc(di)
  # Sync flags.
  var isSync = newSeq[bool](count)
  if not hasStss:
    for i in 0 ..< count: isSync[i] = true
  else:
    for i in 0 ..< count: isSync[i] = false
    for snum in syncs:
      if snum >= 1 and int(snum) <= count:
        isSync[int(snum) - 1] = true
  for i in 0 ..< count:
    checkRange(data, offs[i], sizes[i], "sample data")
    result.samples.add(HeifSample(offset: offs[i], size: sizes[i],
      duration: durs[i], isSync: isSync[i]))

proc parseTfhd(data: seq[uint8], b: Box): tuple[trackId: uint32,
    baseOff: uint64, hasBase: bool, defDur, defSize: uint32,
    hasDur, hasSize: bool, empty: bool] =
  let p = boxPayload(data, b)
  if p.len < 8: raise heifErr("heif: truncated tfhd")
  let flags = (uint32(p[1]) shl 16) or (uint32(p[2]) shl 8) or uint32(p[3])
  result.trackId = rdU32(p, 4)
  var off = 8
  result.hasBase = false
  result.hasDur = false
  result.hasSize = false
  result.empty = (flags and 0x010000'u32) != 0
  if (flags and 0x000001'u32) != 0:
    if p.len < off + 8: raise heifErr("heif: truncated tfhd")
    result.baseOff = rdU64(p, off)
    result.hasBase = true
    off += 8
  if (flags and 0x000002'u32) != 0:
    if p.len < off + 4: raise heifErr("heif: truncated tfhd")
    off += 4 # sample-description-index (single entry assumed)
  if (flags and 0x000008'u32) != 0:
    if p.len < off + 4: raise heifErr("heif: truncated tfhd")
    result.defDur = rdU32(p, off)
    result.hasDur = true
    off += 4
  if (flags and 0x000010'u32) != 0:
    if p.len < off + 4: raise heifErr("heif: truncated tfhd")
    result.defSize = rdU32(p, off)
    result.hasSize = true
    off += 4
  # default-sample-flags (0x000020) and unknown flags: not interpreted;
  # trailing bytes are skipped so forward-compatible flags survive.
  if (flags and 0x020000'u32) != 0 and not result.hasBase:
    # default-base-is-moof: samples are addressed from this moof.
    result.hasBase = false # resolved by the caller to the moof offset

proc mergeTrun(data: seq[uint8], moofOff: int, t: Box, base: uint64,
    defDur, defSize: uint32, hasDur, hasSize: bool,
    track: var HeifTrack) =
  let p = boxPayload(data, t)
  if p.len < 8: raise heifErr("heif: truncated trun")
  let v = p[0]
  if v > 1: raise heifErr("heif: unsupported trun version")
  let flags = (uint32(p[1]) shl 16) or (uint32(p[2]) shl 8) or uint32(p[3])
  var off = 4
  var dataOff: int64 = 0
  if (flags and 0x000001'u32) != 0:
    if p.len < off + 4: raise heifErr("heif: truncated trun")
    let u = rdU32(p, off)
    dataOff = if u >= 0x80000000'u32: int64(u) - 0x100000000'i64 else: int64(u)
    off += 4
  if (flags and 0x000004'u32) != 0:
    if p.len < off + 4: raise heifErr("heif: truncated trun")
    off += 4 # first-sample-flags (sync assumes decodable samples)
  if p.len < off + 4: raise heifErr("heif: truncated trun")
  let scount = rdU32(p, off)
  off += 4
  if scount > 100000: raise heifErr("heif: bad trun sample count")
  let wantDur = (flags and 0x000100'u32) != 0
  let wantSize = (flags and 0x000200'u32) != 0
  let wantFlags = (flags and 0x000400'u32) != 0
  let wantCts = (flags and 0x000800'u32) != 0
  let per = (if wantDur: 4 else: 0) + (if wantSize: 4 else: 0) +
    (if wantFlags: 4 else: 0) + (if wantCts: 4 else: 0)
  if p.len < off + int(scount) * per: raise heifErr("heif: truncated trun")
  if not wantSize and not hasSize:
    raise heifErr("heif: moof sample size unknown")
  discard moofOff
  var cur = int64(base) + dataOff
  for _ in 0 ..< int(scount):
    var dur = defDur
    if wantDur:
      dur = rdU32(p, off); off += 4
    elif not hasDur:
      dur = 0 # timing unknown; samples still decode independently
    var sz = defSize
    if wantSize:
      sz = rdU32(p, off); off += 4
    if wantFlags: off += 4
    if wantCts: off += 4
    if sz == 0 or sz > 64*1024*1024:
      raise heifErr("heif: bad moof sample size")
    if cur < 0 or cur + int64(sz) > int64(data.len):
      raise heifErr("heif: moof sample out of range")
    checkRange(data, int(cur), int(sz), "sample data")
    track.samples.add(HeifSample(offset: int(cur), size: int(sz),
      duration: dur, isSync: true))
    cur += int64(sz)

proc mergeMoofSamples(data: seq[uint8], moof: Box, movie: var HeifMovie) =
  ## Append one moof's traf/trun samples to their tracks (tfhd track_ID).
  for traf in childBoxes(data, moof):
    if not traf.isTypeStr("traf"): continue
    var hasTfhd = false
    var trackId: uint32 = 0
    var base: uint64 = uint64(moof.boxOff) # default-base-is-moof
    var defDur: uint32 = 0
    var defSize: uint32 = 0
    var hasDur, hasSize = false
    var empty = false
    var truns: seq[Box] = @[]
    for c in childBoxes(data, traf):
      if c.isTypeStr("tfhd"):
        let t = parseTfhd(data, c)
        hasTfhd = true
        trackId = t.trackId
        if t.hasBase: base = t.baseOff
        defDur = t.defDur; defSize = t.defSize
        hasDur = t.hasDur; hasSize = t.hasSize
        empty = t.empty
      elif c.isTypeStr("trun"):
        truns.add(c)
      # tfdt/mfhd/sdtp/saio: timing/offsets handled via base+data_offset
    if not hasTfhd: raise heifErr("heif: traf missing tfhd")
    if empty: continue
    var ti = -1
    for i, tr in movie.tracks:
      if tr.trackId == trackId:
        ti = i
        break
    if ti < 0: raise heifErr("heif: moof references unknown track")
    for t in truns:
      mergeTrun(data, moof.boxOff, t, base, defDur, defSize, hasDur,
        hasSize, movie.tracks[ti])

proc parseMovie*(data: seq[uint8]): HeifMovie =
  ## Top-level moov parse. Raises HeifDecodeError on truncation.
  ## Fragmented files (moof) have their samples merged into the matching
  ## tracks (by tfhd track_ID) in file order after the moov is parsed.
  result = HeifMovie()
  var moovBox = Box()
  var foundMoov = false
  var moofBoxes: seq[Box] = @[]
  for b in topLevelBoxes(data):
    if b.isTypeStr("moof"):
      result.hasMoof = true
      moofBoxes.add(b)
    if b.isTypeStr("moov") and not foundMoov:
      foundMoov = true
      moovBox = b
  if not foundMoov:
    raise heifErr("heif: missing moov box")
  var mvTs: uint32 = 0
  var mvDur: uint64 = 0
  for c in childBoxes(data, moovBox):
    if c.isTypeStr("mvhd"):
      parseMvhd(data, c, mvTs, mvDur)
    elif c.isTypeStr("trak"):
      result.tracks.add(parseTrak(data, c))
  result.timescale = mvTs
  result.duration = mvDur
  for m in moofBoxes:
    mergeMoofSamples(data, m, result)

proc hasMovie*(data: seq[uint8]): bool =
  for b in topLevelBoxes(data):
    if b.isTypeStr("moov"): return true
  false

# --- Minimal moov builders (writer side, same shape the reader accepts) ---

proc buildMvhd*(timescale: uint32, duration: uint32): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putU32BE(0) # creation
  p.putU32BE(0) # modification
  p.putU32BE(timescale)
  p.putU32BE(duration)
  p.putU32BE(0x00010000) # rate 1.0
  p.putU16BE(0x0100) # volume
  p.putU16BE(0)
  p.putU32BE(0); p.putU32BE(0)
  for v in [0x00010000'u32, 0, 0, 0, 0x00010000'u32, 0, 0, 0, 0x40000000'u32]:
    p.putU32BE(v)
  for i in 0 ..< 6: p.putU32BE(0) # pre_defined
  p.putU32BE(2) # next_track_ID
  makeFullBox("mvhd", 0, 0, p)

proc buildTkhd*(trackId: uint32, duration: uint32, w, h: int): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putU32BE(0) # creation
  p.putU32BE(0) # modification
  p.putU32BE(trackId)
  p.putU32BE(0) # reserved
  p.putU32BE(duration)
  for i in 0 ..< 2: p.putU32BE(0) # reserved
  p.putU16BE(0) # layer
  p.putU16BE(0) # alternate_group
  p.putU16BE(0) # volume
  p.putU16BE(0) # reserved
  for v in [0x00010000'u32, 0, 0, 0, 0x00010000'u32, 0, 0, 0, 0x40000000'u32]:
    p.putU32BE(v)
  p.putU32BE(uint32(w) shl 16)
  p.putU32BE(uint32(h) shl 16)
  makeFullBox("tkhd", 0, 7, p) # flags 7: enabled/in-movie/in-preview

proc buildMdhd*(timescale: uint32, duration: uint32): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putU32BE(0)
  p.putU32BE(0)
  p.putU32BE(timescale)
  p.putU32BE(duration)
  p.putU16BE(0x55C4) # language und
  p.putU16BE(0)
  makeFullBox("mdhd", 0, 0, p)

proc buildVmhd*(): seq[uint8] =
  var p: seq[uint8] = @[]
  p.putU16BE(0) # graphicsmode
  for i in 0 ..< 3: p.putU16BE(0) # opcolor
  makeFullBox("vmhd", 0, 1, p)

proc buildDinf*(): seq[uint8] =
  var drefInner: seq[uint8] = @[]
  drefInner.putFullHeader(0, 0)
  drefInner.putU32BE(1)
  drefInner.putBytes(makeFullBox("url ", 0, 1, @[]))
  let dref = makeBox("dref", drefInner)
  makeBox("dinf", dref)

proc buildVisualEntry*(coding: string, w, h: int,
    codecBoxes: seq[seq[uint8]]): seq[uint8] =
  var p: seq[uint8] = @[]
  for i in 0 ..< 6: p.add(0)
  p.putU16BE(1) # data_reference_index
  for i in 0 ..< 8: p.putU16BE(0) # pre_defined/reserved (16 bytes)
  p.putU16BE(uint16(w))
  p.putU16BE(uint16(h))
  p.putU32BE(0x00480000) # horizresolution 72 dpi
  p.putU32BE(0x00480000) # vertresolution
  p.putU32BE(0) # reserved
  p.putU16BE(1) # frame_count
  for i in 0 ..< 32: p.add(0) # compressorname
  p.putU16BE(0x0018) # depth
  p.putU16BE(0xFFFF) # pre_defined (signed -1)
  for cb in codecBoxes: p.putBytes(cb)
  makeBox(coding, p)

proc buildStsd*(entries: seq[seq[uint8]]): seq[uint8] =
  var inner: seq[uint8] = @[]
  inner.putFullHeader(0, 0)
  inner.putU32BE(uint32(entries.len))
  for e in entries: inner.putBytes(e)
  makeBox("stsd", inner)

proc buildStts*(count: int, delta: uint32): seq[uint8] =
  var inner: seq[uint8] = @[]
  inner.putFullHeader(0, 0)
  inner.putU32BE(1)
  inner.putU32BE(uint32(count))
  inner.putU32BE(delta)
  makeBox("stts", inner)

proc buildStsc*(chunkCount: int): seq[uint8] =
  ## One sample per chunk (simplest packing our reader accepts).
  var inner: seq[uint8] = @[]
  inner.putFullHeader(0, 0)
  inner.putU32BE(1)
  inner.putU32BE(1)
  inner.putU32BE(1)
  inner.putU32BE(1)
  makeBox("stsc", inner)

proc buildStsz*(sizes: seq[int]): seq[uint8] =
  var inner: seq[uint8] = @[]
  inner.putFullHeader(0, 0)
  inner.putU32BE(0) # uniform = 0, per-sample sizes
  inner.putU32BE(uint32(sizes.len))
  for s in sizes: inner.putU32BE(uint32(s))
  makeBox("stsz", inner)

proc buildStco*(offsets: seq[int]): seq[uint8] =
  var inner: seq[uint8] = @[]
  inner.putFullHeader(0, 0)
  inner.putU32BE(uint32(offsets.len))
  for o in offsets: inner.putU32BE(uint32(o))
  makeBox("stco", inner)
