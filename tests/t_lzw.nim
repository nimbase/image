import unittest
import image/lzw

test "lzw gif round-trip":
  var indices = newSeq[uint8](16)
  for i in 0..<16: indices[i] = uint8(i mod 4)
  let enc = encodeLzwGif(indices, 2)
  let dec = decodeLzwGif(enc, 2, 16)
  check dec.ok
  check dec.value == indices

test "lzw gif single color":
  var indices = newSeq[uint8](32)
  for i in 0..<32: indices[i] = 5
  let enc = encodeLzwGif(indices, 3)
  let dec = decodeLzwGif(enc, 3, 32)
  check dec.ok
  check dec.value == indices
