## GIF codec — references/image/src/codecs/gif.rs (684) + gif@0.14.1
## Header, LSD, GCT/LCT, GCE (disposal/delay/transparent), Netscape loop,
## image descriptors, interlace, LZW sub-blocks, trailer. Pure Nim.
import std/strutils
import ../color
import ../error
import ../buffer
import ../dynamic
import ../animation
import ../lzw

type
  GifDisposal* = enum
    gdNone = 0, gdKeep = 1, gdBackground = 2, gdPrevious = 3

  GifFrame* = object
    left*, top*, width*, height*: uint16
    interlaced*: bool
    delay*: Delay
    disposal*: GifDisposal
    transparent*: tuple[has: bool, index: uint8]
    palette*: seq[tuple[r, g, b: uint8]]
    indices*: seq[uint8]

  GifImage* = object
    width*, height*: uint16
    globalPalette*: seq[tuple[r, g, b: uint8]]
    bgIndex*: uint8
    loopCount*: LoopCount
    frames*: seq[GifFrame]

proc readPalette(data: openArray[uint8], pos: var int, n: int): tuple[ok: bool, pal: seq[tuple[r, g, b: uint8]]] =
  if pos + n * 3 > data.len: return (false, @[])
  var pal = newSeq[tuple[r, g, b: uint8]](n)
  for i in 0..<n:
    pal[i] = (data[pos], data[pos+1], data[pos+2]); pos += 3
  (true, pal)

proc decodeGif*(data: seq[uint8]): ImageResult[GifImage] =
  if data.len < 13:
    return err[GifImage](decodingError("gif: too short"))
  if not (data[0]==uint8('G') and data[1]==uint8('I') and data[2]==uint8('F') and
      data[3]==uint8('8') and (data[4]==uint8('7') or data[4]==uint8('9')) and data[5]==uint8('a')):
    return err[GifImage](decodingError("gif: bad signature"))
  let w = uint16(data[6]) or (uint16(data[7]) shl 8)
  let h = uint16(data[8]) or (uint16(data[9]) shl 8)
  let packed = data[10]
  let bgIndex = data[11]
  # aspect data[12] ignored
  var pos = 13
  var gpal: seq[tuple[r, g, b: uint8]] = @[]
  if (packed and 0x80) != 0:
    let n = 1 shl ((int(packed and 7)) + 1)
    let (ok, pal) = readPalette(data, pos, n)
    if not ok: return err[GifImage](decodingError("gif: truncated GCT"))
    gpal = pal
  var loopCount = infiniteLoop()
  var frames: seq[GifFrame] = @[]
  # pending GCE state
  var gceDelay = delayMs(0)
  var gceDisposal = gdNone
  var gceTransp: tuple[has: bool, index: uint8] = (false, 0)
  var hasGce = false
  template fail(msg: string): untyped =
    return err[GifImage](decodingError("gif: " & msg))
  while true:
    if pos >= data.len: fail("truncated")
    let sep = data[pos]; inc pos
    if sep == 0x3B: break # trailer
    elif sep == 0x21: # extension
      if pos >= data.len: fail("truncated extension")
      let label = data[pos]; inc pos
      if label == 0xF9: # GCE
        if pos >= data.len or data[pos] != 4: fail("bad GCE")
        inc pos
        let p = data[pos]; inc pos
        let delayCs = uint16(data[pos]) or (uint16(data[pos+1]) shl 8); pos += 2
        let transpIdx = data[pos]; inc pos
        if pos >= data.len or data[pos] != 0: fail("bad GCE terminator")
        inc pos
        gceDisposal = GifDisposal((p shr 2) and 7)
        if ord(gceDisposal) > 3: gceDisposal = gdNone
        gceDelay = Delay(numer: uint32(delayCs) * 10, denom: 1000)
        gceTransp = ((p and 1) != 0, transpIdx)
        hasGce = true
      elif label == 0xFF: # app extension (Netscape loop)
        if pos >= data.len: fail("truncated app ext")
        let blockSize = int(data[pos]); inc pos
        if pos + blockSize > data.len: fail("truncated app ext")
        var appId = ""
        for i in 0..<blockSize: appId.add(char(data[pos+i]))
        pos += blockSize
        # sub-blocks
        var appData: seq[uint8] = @[]
        while true:
          if pos >= data.len: fail("truncated app sub-blocks")
          let n = int(data[pos]); inc pos
          if n == 0: break
          if pos + n > data.len: fail("truncated app sub-block")
          for i in 0..<n: appData.add(data[pos+i])
          pos += n
        if appId.startsWith("NETSCAPE2.0") and appData.len >= 3 and appData[0] == 1:
          let loops = uint16(appData[1]) or (uint16(appData[2]) shl 8)
          loopCount = if loops == 0: infiniteLoop() else: finiteLoop(loops)
      else: # skip other extensions (comment 0xFE, plain text 0x01)
        while true:
          if pos >= data.len: fail("truncated ext sub-blocks")
          let n = int(data[pos]); inc pos
          if n == 0: break
          if pos + n > data.len: fail("truncated ext sub-block")
          pos += n
    elif sep == 0x2C: # image descriptor
      if pos + 9 > data.len: fail("truncated descriptor")
      let left = uint16(data[pos]) or (uint16(data[pos+1]) shl 8)
      let top = uint16(data[pos+2]) or (uint16(data[pos+3]) shl 8)
      let iw = uint16(data[pos+4]) or (uint16(data[pos+5]) shl 8)
      let ih = uint16(data[pos+6]) or (uint16(data[pos+7]) shl 8)
      let p = data[pos+8]; pos += 9
      if iw == 0 or ih == 0: fail("empty frame")
      var lpal: seq[tuple[r, g, b: uint8]] = @[]
      if (p and 0x80) != 0:
        let n = 1 shl ((int(p and 7)) + 1)
        let (ok, pal) = readPalette(data, pos, n)
        if not ok: fail("truncated LCT")
        lpal = pal
      if pos >= data.len: fail("truncated LZW min code")
      let minCode = int(data[pos]); inc pos
      if minCode < 2 or minCode > 8: fail("bad LZW min code")
      var comp: seq[uint8] = @[]
      while true:
        if pos >= data.len: fail("truncated LZW blocks")
        let n = int(data[pos]); inc pos
        if n == 0: break
        if pos + n > data.len: fail("truncated LZW block")
        for i in 0..<n: comp.add(data[pos+i])
        pos += n
      let dr = decodeLzwGif(comp, minCode, int(iw) * int(ih))
      if not dr.ok: return err[GifImage](dr.err)
      var indices = dr.value
      if indices.len < int(iw) * int(ih):
        fail("short LZW output")
      indices.setLen(int(iw) * int(ih))
      # deinterlace
      if (p and 0x40) != 0:
        var out2 = newSeq[uint8](indices.len)
        var src = 0
        for passStart in [0, 4, 2, 1]:
          var step = [8, 8, 4, 2][[0,4,2,1].find(passStart)]
          var y = passStart
          while y < int(ih):
            for x in 0..<int(iw):
              out2[y*int(iw)+x] = indices[src]; inc src
            y += step
        indices = out2
      frames.add(GifFrame(left: left, top: top, width: iw, height: ih,
        interlaced: (p and 0x40) != 0, delay: gceDelay, disposal: gceDisposal,
        transparent: gceTransp,
        palette: (if lpal.len > 0: lpal else: gpal), indices: indices))
      hasGce = false
      gceDelay = delayMs(0); gceDisposal = gdNone; gceTransp = (false, 0)
    else:
      fail("unknown block")
  if frames.len == 0:
    fail("no frames")
  ok(GifImage(width: w, height: h, globalPalette: gpal, bgIndex: bgIndex,
    loopCount: loopCount, frames: frames))

proc gifFrameToRgba*(img: GifImage, fi: int): ImageResult[RgbaImage] =
  ## Composite frame fi over canvas using GCT/LCT + transparency + disposal none.
  ## Full disposal compositing across frames is left to the caller; this renders
  ## the frame's own rectangle.
  if fi < 0 or fi >= img.frames.len:
    return err[RgbaImage](paramError(pkGeneric, "gif: frame out of range"))
  let f = img.frames[fi]
  let pal = f.palette
  var px = newSeq[Rgba[uint8]](int(f.width) * int(f.height))
  for i, idx in f.indices:
    if f.transparent.has and idx == f.transparent.index:
      px[i] = Rgba[uint8](data: [0'u8, 0, 0, 0])
    elif int(idx) < pal.len:
      let c = pal[int(idx)]
      px[i] = Rgba[uint8](data: [c.r, c.g, c.b, 255'u8])
    else:
      return err[RgbaImage](decodingError("gif: palette index out of range"))
  ok(RgbaImage(width: uint32(f.width), height: uint32(f.height), pixels: move(px)))

proc gifFirstToRgba*(data: seq[uint8]): ImageResult[RgbaImage] =
  let g = decodeGif(data)
  if not g.ok: return err[RgbaImage](g.err)
  gifFrameToRgba(g.value, 0)

proc encodeGif*(frames: seq[seq[uint8]], width, height: uint16,
    palette: seq[tuple[r, g, b: uint8]], delaysCs: seq[uint16] = @[]): seq[uint8] =
  ## Minimal GIF89a encoder: GCT 256 entries (pow2), one frame per indices seq.
  var n = 1
  while n < palette.len: n *= 2
  n = max(n, 2)
  var minCode = 1
  while (1 shl minCode) < n: inc minCode
  minCode = clamp(minCode, 2, 8)
  result = @[uint8('G'), uint8('I'), uint8('F'), uint8('8'), uint8('9'), uint8('a')]
  result.add([uint8(width and 0xFF), uint8((width shr 8) and 0xFF),
    uint8(height and 0xFF), uint8((height shr 8) and 0xFF)])
  var sizeBits = 0
  var t = n
  while t > 2: t = t div 2; inc sizeBits
  let packed = uint8(0x80 or 0x70 or sizeBits)
  result.add([packed, 0'u8, 0])
  for i in 0..<n:
    if i < palette.len: result.add([palette[i].r, palette[i].g, palette[i].b])
    else: result.add([0'u8, 0, 0])
  if frames.len > 1:
    # Netscape infinite loop
    result.add([0x21'u8, 0xFF, 11])
    for c in "NETSCAPE2.0": result.add(uint8(c))
    result.add([3'u8, 1, 0, 0, 0])
  for fi, idx in frames:
    let dc = if fi < delaysCs.len: delaysCs[fi] else: 0'u16
    if dc != 0 or true:
      result.add([0x21'u8, 0xF9, 4, 0,
        uint8(dc and 0xFF), uint8((dc shr 8) and 0xFF), 0, 0])
    result.add([0x2C'u8, 0, 0, 0, 0,
      uint8(width and 0xFF), uint8((width shr 8) and 0xFF),
      uint8(height and 0xFF), uint8((height shr 8) and 0xFF), 0])
    result.add(uint8(minCode))
    let comp = encodeLzwGif(idx, minCode)
    var p = 0
    while p < comp.len:
      let k = min(255, comp.len - p)
      result.add(uint8(k))
      for i in 0..<k: result.add(comp[p+i])
      p += k
    result.add(0'u8)
  result.add(0x3B'u8)
