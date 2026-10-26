import unittest
import image
import image/codecs/gif

test "gif round-trip single frame":
  let pal = @[(255'u8, 0'u8, 0'u8), (0'u8, 255'u8, 0'u8),
              (0'u8, 0'u8, 255'u8), (255'u8, 255'u8, 255'u8)]
  let idx = @[0'u8, 1, 2, 3]
  let enc = encodeGif(@[idx], 2, 2, pal)
  check enc[0] == uint8('G')
  let dec = decodeGif(enc)
  check dec.ok
  check dec.value.width == 2
  check dec.value.frames.len == 1
  let rgba = gifFrameToRgba(dec.value, 0)
  check rgba.ok
  check rgba.value.pixels[0].data == [255'u8, 0, 0, 255'u8]
  check rgba.value.pixels[3].data == [255'u8, 255, 255, 255'u8]

test "gif interlaced":
  let pal = @[(0'u8, 0'u8, 0'u8), (255'u8, 255'u8, 255'u8)]
  var idx = newSeq[uint8](16)
  for i in 0..<16: idx[i] = uint8(i mod 2)
  let enc = encodeGif(@[idx], 4, 4, pal)
  # flip on interlace bit + re-encode path exercised via manual header patch:
  # descriptor packed byte is at offset 13+... find 0x2C
  var patched = enc
  for i in 0..<patched.len-10:
    if patched[i] == 0x2C:
      patched[i+9] = patched[i+9] or 0x40
      break
  let dec = decodeGif(patched)
  check dec.ok
  # interlaced decode of non-interlaced data won't match; just check shape
  check dec.value.frames[0].interlaced
  check dec.value.frames[0].indices.len == 16

test "gif animation + loop":
  let pal = @[(0'u8, 0'u8, 0'u8), (255'u8, 0'u8, 0'u8)]
  let f0 = @[0'u8, 0, 0, 0]
  let f1 = @[1'u8, 1, 1, 1]
  let enc = encodeGif(@[f0, f1], 2, 2, pal, @[10'u16, 20])
  let dec = decodeGif(enc)
  check dec.ok
  check dec.value.frames.len == 2
  check dec.value.frames[0].delay.toMs() == 100
  check dec.value.frames[1].delay.toMs() == 200

test "gif bad signature":
  check decodeGif(@[0'u8, 1, 2]).ok == false

test "gif truncated":
  let pal = @[(0'u8, 0'u8, 0'u8), (255'u8, 255'u8, 255'u8)]
  var enc = encodeGif(@[@[0'u8, 1, 0, 1]], 2, 2, pal)
  enc.setLen(enc.len - 5)
  check decodeGif(enc).ok == false
