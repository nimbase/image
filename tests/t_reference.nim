## Reference / regression suite (plan 7.2): every vendored fixture under
## `tests/fixtures/` must decode (or fail cleanly where unsupported by
## design). Pixel-exact assertions live in t_jpeg/t_exr/t_webp; this is
## the gate that no fixture regresses to an error or crash.
## Expected failures: EXR PIZ (`overexposed gradient…`, tiled/multipart
## unsupported) and lossy VP8 (`lossy_images/`, VP8 bitstream unsupported).
import unittest
import std/os
import std/strutils
import image
import image/codecs/[jpeg, openexr, webp]

let fixturesDir = currentSourcePath().parentDir() / "fixtures"

proc readRaw(p: string): seq[uint8] =
  var f = open(p, fmRead)
  result = newSeq[uint8](getFileSize(f))
  discard readBytes(f, result, 0, result.len)
  close(f)

test "reference fixtures decode":
  var count = 0
  for p in walkDirRec(fixturesDir):
    if dirExists(p): continue
    let ext = splitFile(p).ext.toLowerAscii()
    let expectFail = p.contains("overexposed gradient") or
      p.contains("lossy_images")
    case ext
    of ".jpg", ".jpeg":
      let dec = decodeJpeg(readRaw(p))
      if expectFail: check dec.ok == false
      else:
        check dec.ok
        check dec.value.dimensions()[0] > 0 and dec.value.dimensions()[1] > 0
    of ".exr":
      let dec = decodeExr(readRaw(p))
      if expectFail: check dec.ok == false
      else:
        check dec.ok
        check dec.value.dimensions()[0] > 0 and dec.value.dimensions()[1] > 0
    of ".webp":
      let dec = decodeWebp(readRaw(p))
      if expectFail: check dec.ok == false
      else:
        check dec.ok
        check dec.value.dimensions()[0] > 0 and dec.value.dimensions()[1] > 0
    else:
      check false # stray fixture: triage it into the suite
    inc(count)
  check count == 13 # bump when fixtures are added/removed
