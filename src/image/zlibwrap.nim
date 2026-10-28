## Deflate/inflate + CRC32 via the nimbase `archive` library (pure Nim).
## Drop-in replacement for the former pkg/zlib C dependency.
##
## Memory discipline: inputs are borrowed (no seq->string copy) and
## inflate outputs are pre-sized when the caller knows the exact size,
## so large images don't pay doubling growth or duplicate buffers.
import archive/zlibf
import archive/io
import archive/crc32
import ../image/error

proc borrowInput(data: openArray[uint8]): Input =
  ## Zero-copy Input over the caller's bytes. Safe: the borrow never
  ## outlives this call (archive only reads during the one-shot call,
  ## and `data` stays referenced by our caller throughout).
  if data.len == 0: openInputBorrowed(nil, 0)
  else: openInputBorrowed(unsafeAddr data[0], data.len)

proc stringToBytes(s: string): seq[uint8] =
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc inflateZlib*(data: openArray[uint8], expectedLen: int): ImageResult[seq[uint8]] =
  ## `expectedLen` pre-sizes the output (no growth reallocs when exact,
  ## the common case: PNG/TIFF/EXR/HEIF all know it upfront). Overrun
  ## still grows; short output is reported by callers as before.
  try:
    var dst = newOutput(max(expectedLen, 0))
    zlibDecompressInto(borrowInput(data), dst)
    ok(stringToBytes(take(dst)))
  except CatchableError as e:
    err[seq[uint8]](decodingError("inflate failed: " & e.msg))

proc inflateZlibStr*(data: openArray[uint8],
    expectedLen: int): ImageResult[string] =
  ## String variant: same pre-sized one-shot inflate, but hands over
  ## the exact-size output string WITHOUT copying it into a seq first.
  ## Use when the caller can index bytes directly (saves one full-size
  ## copy on large images).
  try:
    var dst = newOutput(max(expectedLen, 0))
    zlibDecompressInto(borrowInput(data), dst)
    ok(take(dst))
  except CatchableError as e:
    err[string](decodingError("inflate failed: " & e.msg))

proc inflateZlibGrow*(data: openArray[uint8], maxOut = 256 * 1024 * 1024): ImageResult[seq[uint8]] =
  ## Unknown output size; `maxOut` caps the accepted result.
  try:
    var dst = newOutput()
    zlibDecompressInto(borrowInput(data), dst)
    let s = take(dst)
    if s.len > maxOut:
      return err[seq[uint8]](limitError(lkInsufficientMemory,
        "inflate output exceeds limit"))
    ok(stringToBytes(s))
  except CatchableError as e:
    err[seq[uint8]](decodingError("inflate failed: " & e.msg))

proc deflateZlib*(data: openArray[uint8], level = 6): ImageResult[seq[uint8]] =
  try:
    # Start small: typical deflated output is far below input size;
    # incompressible input still grows correctly via doubling.
    var dst = newOutput(max(data.len div 8, 1024))
    zlibCompressInto(borrowInput(data), dst, level)
    ok(stringToBytes(take(dst)))
  except CatchableError as e:
    err[seq[uint8]](encodingError("deflate failed: " & e.msg))

func crc32raw*(data: openArray[uint8]): uint32 =
  if data.len == 0: return 0
  crc32Checksum(data)
