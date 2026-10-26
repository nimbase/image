## zlib helpers via pkg/zlib (allowed C dep) for PNG IDAT / TIFF deflate.
import zlib/zlib_api
import ../image/error

proc inflateZlib*(data: openArray[uint8], expectedLen: int): ImageResult[seq[uint8]] =
  var outLen = expectedLen
  if outLen <= 0: outLen = data.len * 4 + 64
  var output = newSeq[uint8](outLen)
  var dstLen = culong(outLen)
  let rc =
    if data.len == 0: Z_BUF_ERROR
    else:
      uncompress(addr output[0], dstLen,
        cast[ptr uint8](unsafeAddr data[0]), culong(data.len))
  if rc != Z_OK:
    return err[seq[uint8]](decodingError("zlib inflate failed: " & $rc))
  output.setLen(int(dstLen))
  ok(output)

proc inflateZlibGrow*(data: openArray[uint8], maxOut = 256 * 1024 * 1024): ImageResult[seq[uint8]] =
  ## Unknown output size: try doubling from 64KB.
  var cap = 65536
  while cap <= maxOut:
    var output = newSeq[uint8](cap)
    var dstLen = culong(cap)
    let rc =
      if data.len == 0: Z_BUF_ERROR
      else:
        uncompress(addr output[0], dstLen,
          cast[ptr uint8](unsafeAddr data[0]), culong(data.len))
    if rc == Z_OK:
      output.setLen(int(dstLen))
      return ok(output)
    elif rc == Z_BUF_ERROR:
      cap *= 2
      continue
    else:
      return err[seq[uint8]](decodingError("zlib inflate failed: " & $rc))
  err[seq[uint8]](limitError(lkInsufficientMemory, "zlib output exceeds limit"))

proc deflateZlib*(data: openArray[uint8], level = 6): ImageResult[seq[uint8]] =
  let bound = int(compressBound(culong(data.len)))
  var output = newSeq[uint8](bound)
  var dstLen = culong(bound)
  let rc =
    if data.len == 0:
      var empty: uint8 = 0
      compress2(addr output[0], dstLen, addr empty, 0, cint(level))
    else:
      compress2(addr output[0], dstLen,
        cast[ptr uint8](unsafeAddr data[0]), culong(data.len), cint(level))
  if rc != Z_OK:
    return err[seq[uint8]](encodingError("zlib deflate failed: " & $rc))
  output.setLen(int(dstLen))
  ok(output)

func crc32raw*(data: openArray[uint8]): uint32 =
  if data.len == 0: return 0
  uint32(crc32(0, cast[ptr uint8](unsafeAddr data[0]), cuint(data.len)))
