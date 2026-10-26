## Deflate/inflate + CRC32 via the nimbase `archive` library (pure Nim).
## Drop-in replacement for the former pkg/zlib C dependency.
import archive/zlibf
import archive/crc32
import ../image/error

proc bytesToString(data: openArray[uint8]): string =
  result = newString(data.len)
  if data.len > 0:
    copyMem(addr result[0], unsafeAddr data[0], data.len)

proc stringToBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc inflateZlib*(data: openArray[uint8], expectedLen: int): ImageResult[seq[uint8]] =
  ## `expectedLen` is advisory only; the archive backend grows its output.
  try:
    ok(stringToBytes(zlibDecompress(bytesToString(data))))
  except CatchableError as e:
    err[seq[uint8]](decodingError("inflate failed: " & e.msg))

proc inflateZlibGrow*(data: openArray[uint8], maxOut = 256 * 1024 * 1024): ImageResult[seq[uint8]] =
  ## Unknown output size; `maxOut` caps the accepted result.
  try:
    let output = stringToBytes(zlibDecompress(bytesToString(data)))
    if output.len > maxOut:
      return err[seq[uint8]](limitError(lkInsufficientMemory,
        "inflate output exceeds limit"))
    ok(output)
  except CatchableError as e:
    err[seq[uint8]](decodingError("inflate failed: " & e.msg))

proc deflateZlib*(data: openArray[uint8], level = 6): ImageResult[seq[uint8]] =
  try:
    ok(stringToBytes(zlibCompress(bytesToString(data), level)))
  except CatchableError as e:
    err[seq[uint8]](encodingError("deflate failed: " & e.msg))

func crc32raw*(data: openArray[uint8]): uint32 =
  if data.len == 0: return 0
  crc32Checksum(data)
