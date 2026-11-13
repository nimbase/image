## Timed image sequences (clean-room, MIT).
## Parses ISOBMFF `moov` with `pict` tracks (sample tables) and builds
## matching files. Only uncompressed v1 (`rgb3`/`rgba`) and JPEG samples
## are decoded; video bitstreams stay Unsupported (passthrough).
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
    if tot == 0 or tot > 100000: raise heifErr("heif: bad sequence length")
    count = tot
  else:
    count = stszSizes.len
  if count == 0 or count > 100000: raise heifErr("heif: bad sequence length")
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

proc parseMovie*(data: seq[uint8]): HeifMovie =
  ## Top-level moov parse. Raises HeifDecodeError on truncation.
  result = HeifMovie()
  var foundMoov = false
  for b in topLevelBoxes(data):
    if b.isTypeStr("moof"):
      result.hasMoof = true
    if b.isTypeStr("moov") and not foundMoov:
      foundMoov = true
      var mvTs: uint32 = 0
      var mvDur: uint64 = 0
      for c in childBoxes(data, b):
        if c.isTypeStr("mvhd"):
          parseMvhd(data, c, mvTs, mvDur)
        elif c.isTypeStr("trak"):
          result.tracks.add(parseTrak(data, c))
      result.timescale = mvTs
      result.duration = mvDur
  if not foundMoov:
    raise heifErr("heif: missing moov box")

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
