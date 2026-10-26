import unittest
import image
import image/codecs/ico

test "ico png round-trip":
  var px = @[Rgba[uint8](data: [255'u8, 0, 0, 255'u8]),
             Rgba[uint8](data: [0'u8, 255, 0, 255'u8]),
             Rgba[uint8](data: [0'u8, 0, 255, 255'u8]),
             Rgba[uint8](data: [0'u8, 0, 0, 0'u8])]
  let img = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 2, height: 2, pixels: px))
  let enc = encodeIco(@[img])
  check enc.ok
  check enc.value[0] == 0 and enc.value[2] == 1
  let dec = decodeIco(enc.value)
  check dec.ok
  check dec.value.kind == dkRgba8
  check dec.value.rgba8.pixels == px

test "ico largest wins":
  var small = newSeq[Rgba[uint8]](1)
  small[0] = Rgba[uint8](data: [1'u8, 2, 3, 255'u8])
  var big = newSeq[Rgba[uint8]](16)
  for i in 0..<16: big[i] = Rgba[uint8](data: [9'u8, 9, 9, 255'u8])
  let si = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 1, height: 1, pixels: small))
  let bi = DynamicImage(kind: dkRgba8, rgba8: RgbaImage(width: 4, height: 4, pixels: big))
  let enc = encodeIco(@[si, bi])
  check enc.ok
  let dec = decodeIco(enc.value)
  check dec.ok
  check dec.value.dimensions() == (4'u32, 4'u32)

test "ico bmp payload with AND mask":
  # Build 2x1 24-bit BMP DIB (height doubled=2) + AND mask via bmp encoder pieces:
  # DIB: 40-byte header + pixel rows (bottom-up, padded) + AND mask rows.
  var dib = newSeq[uint8](40)
  dib[0] = 40
  dib[4] = 2 # width
  dib[8] = 2 # height doubled (XOR + AND)
  dib[12] = 1 # planes
  dib[14] = 24 # bpp
  # pixel rows bottom-up: row1 (bottom): red,green; row0: blue,white; padded to 4
  dib.add([0'u8, 0, 255, 255, 255, 255, 0, 0]) # BGR blue,white + pad
  dib.add([0'u8, 0, 255, 0, 255, 0, 0, 0])     # BGR red,green + pad
  # AND mask: 1 row per image row (hAct=1)... hAct = 2 div 2 = 1? No: height=2 -> hAct=1.
  # Wait: we want 2x1 image: doubled height = 2, hAct = 1. Rows above are 2 rows = XOR.
  # AND mask: 1 row, stride 4: mark pixel (0,0) transparent: bit7 of first byte.
  dib.add([0x80'u8, 0, 0, 0])
  let dec = decodeBmpIcoPayload(dib)
  check dec.ok
  check dec.value.kind == dkRgba8
  check dec.value.rgba8.width == 2
  # top row = first file row (BGR): red, white; AND mask marks x=0 transparent
  check dec.value.rgba8.pixels[0].data == [255'u8, 0, 0, 0]
  check dec.value.rgba8.pixels[1].data == [255'u8, 255, 255, 255]

test "ico bad header":
  check decodeIco(@[0'u8, 1, 2]).ok == false
