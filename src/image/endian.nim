## Big/little endian helpers (replaces byteorder-lite).
import streams

proc readU16BE*(s: Stream): uint16 =
  let b = s.readStr(2)
  if b.len < 2: raise newException(IOError, "unexpected EOF reading u16BE")
  (uint16(uint8(b[0])) shl 8) or uint16(uint8(b[1]))

proc readU16LE*(s: Stream): uint16 =
  let b = s.readStr(2)
  if b.len < 2: raise newException(IOError, "unexpected EOF reading u16LE")
  (uint16(uint8(b[1])) shl 8) or uint16(uint8(b[0]))

proc readU32BE*(s: Stream): uint32 =
  let b = s.readStr(4)
  if b.len < 4: raise newException(IOError, "unexpected EOF reading u32BE")
  (uint32(uint8(b[0])) shl 24) or (uint32(uint8(b[1])) shl 16) or
    (uint32(uint8(b[2])) shl 8) or uint32(uint8(b[3]))

proc readU32LE*(s: Stream): uint32 =
  let b = s.readStr(4)
  if b.len < 4: raise newException(IOError, "unexpected EOF reading u32LE")
  (uint32(uint8(b[3])) shl 24) or (uint32(uint8(b[2])) shl 16) or
    (uint32(uint8(b[1])) shl 8) or uint32(uint8(b[0]))

proc writeU16BE*(s: Stream, v: uint16) =
  var b = newString(2)
  b[0] = char((v shr 8) and 0xFF)
  b[1] = char(v and 0xFF)
  s.write(b)

proc writeU16LE*(s: Stream, v: uint16) =
  var b = newString(2)
  b[0] = char(v and 0xFF)
  b[1] = char((v shr 8) and 0xFF)
  s.write(b)

proc writeU32BE*(s: Stream, v: uint32) =
  var b = newString(4)
  b[0] = char((v shr 24) and 0xFF)
  b[1] = char((v shr 16) and 0xFF)
  b[2] = char((v shr 8) and 0xFF)
  b[3] = char(v and 0xFF)
  s.write(b)

proc writeU32LE*(s: Stream, v: uint32) =
  var b = newString(4)
  b[0] = char(v and 0xFF)
  b[1] = char((v shr 8) and 0xFF)
  b[2] = char((v shr 16) and 0xFF)
  b[3] = char((v shr 24) and 0xFF)
  s.write(b)

func u16BE*(data: openArray[uint8], off = 0): uint16 =
  (uint16(data[off]) shl 8) or uint16(data[off+1])

func u32BE*(data: openArray[uint8], off = 0): uint32 =
  (uint32(data[off]) shl 24) or (uint32(data[off+1]) shl 16) or
    (uint32(data[off+2]) shl 8) or uint32(data[off+3])
