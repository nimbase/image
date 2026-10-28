## Uncompressed HEIF frame decoder (clean-room, ISO/IEC 23001-17).
## Interprets uncC/cmpd/cmpC descriptors plus pixi/ispe/nclx properties and
## turns the (optionally zlib/deflate-compressed) frame bytes into a
## DynamicImage. Tiled layouts, 10/12-bit YUV and exotic component orders
## return Unsupported; truncation/mismatch returns Decoding errors.
import std/math
import archive/flate
import ../../error
import ../../buffer
import ../../dynamic
import ../../color
import ../avif
import ../../zlibwrap
import ./props

proc nclxMatrix(m: int): YuvMatrix =
  case m
  of 1, 4: ymBT709
  of 5, 6, 7: ymBT601
  of 9, 10: ymBT2020
  else: ymBT601 # unspecified/identity fallback, documented

proc stringToBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc decompressFrame*(raw: seq[uint8], cmpPayload: seq[uint8],
    expectedLen: int): ImageResult[seq[uint8]] =
  ## cmpC absent (empty payload) means no compression.
  if cmpPayload.len == 0:
    return ok(raw)
  let id = parseCmpC(cmpPayload)
  if id == "zlib":
    let r = inflateZlib(raw, expectedLen)
    if not r.ok: return err[seq[uint8]](r.err)
    ok(r.value)
  elif id == "defl":
    try:
      var s = newString(raw.len)
      if raw.len > 0:
        copyMem(addr s[0], unsafeAddr raw[0], raw.len)
      ok(stringToBytes(inflateAll(s)))
    except CatchableError as e:
      err[seq[uint8]](decodingError("heif: deflate failed: " & e.msg))
  else:
    err[seq[uint8]](unsupportedError(ukGenericFeature,
      "heif: uncompressed compressor '" & id & "' unsupported"))

func compBytesAt(frame: seq[uint8], off: int, bpc: int): uint16 =
  if bpc == 1: uint16(frame[off])
  else: (uint16(frame[off]) shl 8) or uint16(frame[off + 1])

proc scaleTo16(v: uint16, depth: int): uint16 =
  if depth == 16: v
  else: uint16((uint32(v) * 65535'u32) div uint32((1 shl depth) - 1))

proc decodeUncompressed*(frame: seq[uint8], prof: UncProfile,
    comps: seq[CmpEntry], pixi: PixInfo, width, height: int,
    matrix: int, fullRange: bool): ImageResult[DynamicImage] =
  ## Full frame decode. `frame` is post-decompression raw bytes.
  var order: seq[int] # component type ids in storage order
  var interleave, sampling, depth: int
  if prof.isV1:
    case prof.v1Tag
    of "rgb3": order = @[4, 5, 6]
    of "rgba": order = @[4, 5, 6, 7]
    else:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: uncompressed v1 profile '" & prof.v1Tag & "' unsupported"))
    interleave = 1
    sampling = 0
    # pixi num_channels is unreliable for v1 profiles in the wild (observed
    # count=1 for 3-channel rgb3); the profile tag implies the layout and
    # all observed v1 frames are 8-bit. Depth is cross-checked by frame size.
    depth = 8
  else:
    if comps.len == 0:
      return err[DynamicImage](decodingError("heif: missing cmpd"))
    if pixi.bits.len != comps.len:
      return err[DynamicImage](decodingError("heif: pixi/cmpd mismatch"))
    depth = prof.bitDepth
    for b in pixi.bits:
      if b != depth:
        return err[DynamicImage](decodingError("heif: pixi/uncC mismatch"))
    if depth != 8 and depth != 16:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: uncompressed bit depth unsupported"))
    if prof.tiled:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: tiled uncompressed layout unsupported"))
    for c in comps: order.add(c.compType)
    interleave = prof.interleave
    sampling = prof.sampling
  let bpc = depth div 8
  let n = order.len
  # Subsampling geometry applies to YUV orders only, in any cmpd order
  # (YUV, YVU, VUY all observed). RGB/mono writers emit full-resolution
  # planes (verified by frame-size checks on every fixture); component
  # type 0 (monochrome/direct) is accepted as mono alongside 1; unknown
  # types in RGB context are consumed as full planes but ignored for
  # mapping (e.g. the pad component in RGxB fixtures).
  var cw = width
  var ch = height
  proc hasAll(ts: seq[int]): bool =
    for t in ts:
      var f = false
      for o in order:
        if o == t:
          f = true
          break
      if not f: return false
    true
  let isYuv = order.len == 3 and hasAll(@[1, 2, 3])
  if isYuv:
    if sampling == 1:
      cw = (width + 1) div 2
    elif sampling == 2:
      cw = (width + 1) div 2
      ch = (height + 1) div 2
  let monoOk = (n == 1 and (order[0] == 1 or order[0] == 0))
  if interleave == 4:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "heif: tile-component interleave unsupported"))
  if interleave == 3 and isYuv and sampling != 0:
    return err[DynamicImage](unsupportedError(ukGenericFeature,
      "heif: row interleave with subsampling unsupported"))
  # expected frame size
  var expected = 0
  if interleave == 0:
    if isYuv and sampling != 0:
      expected = (width * height + 2 * cw * ch) * bpc
    else:
      expected = width * height * n * bpc
  elif interleave == 1 or interleave == 3:
    expected = width * height * n * bpc
  else: # mixed: Y plane + interleaved CbCr
    if not isYuv or sampling == 0:
      return err[DynamicImage](decodingError("heif: bad mixed interleave"))
    expected = (width * height + 2 * cw * ch) * bpc
  if frame.len != expected:
    return err[DynamicImage](decodingError("heif: uncompressed size mismatch"))
  # component planes as uint16 values (native range, BE for 16-bit)
  var planes = newSeq[seq[uint16]](n)
  for k in 0 ..< n: planes[k] = newSeq[uint16](width * height)
  proc findIdx(t: int): int =
    for i, o in order:
      if o == t: return i
    -1
  if interleave == 1:
    let stride = n * bpc
    for y in 0 ..< height:
      for x in 0 ..< width:
        let base = y * width * stride + x * stride
        for k in 0 ..< n:
          planes[k][y * width + x] =
            compBytesAt(frame, base + k * bpc, bpc)
  elif interleave == 3:
    # row interleave: each row holds every component's row in cmpd order
    var pos = 0
    for y in 0 ..< height:
      for k in 0 ..< n:
        for x in 0 ..< width:
          planes[k][y * width + x] = compBytesAt(frame, pos, bpc)
          pos += bpc
  elif interleave == 0:
    # Component interleave: planes stored in cmpd order, each sized by
    # component ROLE (Y full; Cb/Cr subsampled). Verified on YUV/YVU/VUY
    # 420/422 fixtures: geometry follows the type id, not the position.
    # Unknown-typed planes are still consumed so the size check stays exact.
    var pos = 0
    for k in 0 ..< n:
      var pw = width
      var ph = height
      let sub = isYuv and sampling != 0 and
        (order[k] == 2 or order[k] == 3)
      if sub:
        pw = cw
        ph = ch
      for yy in 0 ..< ph:
        for xx in 0 ..< pw:
          let v = compBytesAt(frame, pos, bpc)
          pos += bpc
          if sub:
            # replicate subsampled chroma to full resolution
            let fx = 2
            let fy = if sampling == 2: 2 else: 1
            for dy in 0 ..< fy:
              for dx in 0 ..< fx:
                let ox = min(width - 1, xx * fx + dx)
                let oy = min(height - 1, yy * fy + dy)
                planes[k][oy * width + ox] = v
          else:
            planes[k][yy * width + xx] = v
  else: # mixed
    # Y plane (full) at the Y component's position; the two chroma
    # components share one interleaved pair block at the first chroma
    # position, pair elements in cmpd order. Verified on YUV/YVU/VUY 420.
    var yPos = -1
    for k in 0 ..< n:
      if order[k] == 1 and yPos < 0: yPos = k
    # pair block starts after all full planes preceding the first chroma
    var pos = 0
    var pairAt = -1
    for k in 0 ..< n:
      if order[k] == 1:
        for i in 0 ..< width * height:
          planes[k][i] = compBytesAt(frame, pos + i * bpc, bpc)
        pos += width * height * bpc
      elif order[k] == 2 or order[k] == 3:
        if pairAt < 0:
          pairAt = pos
          pos += 2 * cw * ch * bpc
    if yPos < 0 or pairAt < 0:
      return err[DynamicImage](decodingError("heif: bad mixed interleave"))
    pos = pairAt
    # chroma indices in cmpd order get pair[0], pair[1] respectively
    var cIdx: seq[int] = @[]
    for k in 0 ..< n:
      if order[k] == 2 or order[k] == 3: cIdx.add(k)
    for yy in 0 ..< ch:
      for xx in 0 ..< cw:
        let v0 = compBytesAt(frame, pos, bpc)
        let v1 = compBytesAt(frame, pos + bpc, bpc)
        pos += 2 * bpc
        let fx = 2
        let fy = if sampling == 2: 2 else: 1
        for dy in 0 ..< fy:
          for dx in 0 ..< fx:
            let ox = min(width - 1, xx * fx + dx)
            let oy = min(height - 1, yy * fy + dy)
            planes[cIdx[0]][oy * width + ox] = v0
            planes[cIdx[1]][oy * width + ox] = v1
  # map to DynamicImage by component order
  if monoOk:
    if depth == 8:
      var px = newSeq[Luma[uint8]](width * height)
      for i in 0 ..< px.len: px[i] = Luma[uint8](data: [uint8(planes[0][i])])
      return ok(DynamicImage(kind: dkLuma8,
        luma8: GrayImage(width: uint32(width), height: uint32(height),
          pixels: px)))
    else:
      var px = newSeq[Luma[uint16]](width * height)
      for i in 0 ..< px.len:
        px[i] = Luma[uint16](data: [scaleTo16(planes[0][i], depth)])
      return ok(DynamicImage(kind: dkLuma16,
        luma16: Gray16Image(width: uint32(width), height: uint32(height),
          pixels: px)))
  let ri = findIdx(4)
  let gi = findIdx(5)
  let bi = findIdx(6)
  let ai = findIdx(7)
  if ri >= 0 and gi >= 0 and bi >= 0 and not isYuv:
    if ai >= 0:
      if depth == 8:
        var px = newSeq[Rgba[uint8]](width * height)
        for i in 0 ..< px.len:
          px[i] = Rgba[uint8](data: [uint8(planes[ri][i]),
            uint8(planes[gi][i]), uint8(planes[bi][i]),
            uint8(planes[ai][i])])
        return ok(DynamicImage(kind: dkRgba8,
          rgba8: RgbaImage(width: uint32(width), height: uint32(height),
            pixels: px)))
      else:
        var px = newSeq[Rgba[uint16]](width * height)
        for i in 0 ..< px.len:
          px[i] = Rgba[uint16](data: [scaleTo16(planes[ri][i], depth),
            scaleTo16(planes[gi][i], depth), scaleTo16(planes[bi][i], depth),
            scaleTo16(planes[ai][i], depth)])
        return ok(DynamicImage(kind: dkRgba16,
          rgba16: Rgba16Image(width: uint32(width), height: uint32(height),
            pixels: px)))
    else:
      # no-alpha RGB: extra unknown-typed components (e.g. pad) are
      # consumed in layout but ignored here
      if depth == 8:
        var px = newSeq[Rgb[uint8]](width * height)
        for i in 0 ..< px.len:
          px[i] = Rgb[uint8](data: [uint8(planes[ri][i]),
            uint8(planes[gi][i]), uint8(planes[bi][i])])
        return ok(DynamicImage(kind: dkRgb8,
          rgb8: RgbImage(width: uint32(width), height: uint32(height),
            pixels: px)))
      else:
        var px = newSeq[Rgb[uint16]](width * height)
        for i in 0 ..< px.len:
          px[i] = Rgb[uint16](data: [scaleTo16(planes[ri][i], depth),
            scaleTo16(planes[gi][i], depth), scaleTo16(planes[bi][i], depth)])
        return ok(DynamicImage(kind: dkRgb16,
          rgb16: Rgb16Image(width: uint32(width), height: uint32(height),
            pixels: px)))
  if isYuv:
    if depth != 8:
      return err[DynamicImage](unsupportedError(ukGenericFeature,
        "heif: 16-bit YUV uncompressed unsupported"))
    # cmpd order varies (YUV, YVU, VUY); map by component type id
    let yi = findIdx(1)
    let ui = findIdx(2)
    let vi = findIdx(3)
    var y = newSeq[uint8](width * height)
    var u = newSeq[uint8](width * height)
    var v = newSeq[uint8](width * height)
    for i in 0 ..< y.len:
      y[i] = uint8(planes[yi][i])
      u[i] = uint8(planes[ui][i])
      v[i] = uint8(planes[vi][i])
    let m = nclxMatrix(matrix)
    let r = if fullRange: yrFull else: yrLimited
    return ok(DynamicImage(kind: dkRgb8,
      rgb8: yuv444ToRgb(y, u, v, width, height, m, r)))
  err[DynamicImage](unsupportedError(ukGenericFeature,
    "heif: uncompressed component order unsupported"))
