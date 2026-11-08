import unittest
import std/os
import std/strutils
import image
import image/codecs/openexr

let fixturesDir = currentSourcePath().parentDir() / "fixtures"

test "half conversions":
  check halfToFloat(0x0000'u16) == 0.0f32
  check halfToFloat(0x3C00'u16) == 1.0f32
  check halfToFloat(0xBC00'u16) == -1.0f32
  check halfToFloat(0x7C00'u16) == Inf.float32
  check floatToHalf(1.0f32) == 0x3C00'u16
  check floatToHalf(0.0f32) == 0x0000'u16
  check floatToHalf(-0.0f32) == 0x8000'u16
  check floatToHalf(65504.0f32) == 0x7BFF'u16
  # round-trip of a normal value
  check halfToFloat(floatToHalf(0.33325195f32)) == halfToFloat(0x3555'u16)
  # round-to-nearest-even (truncation gives 0xD16A/0xBCFE here instead)
  check floatToHalf(-43.333332f32) == 0xD16B'u16
  check floatToHalf(0.33333334f32) == 0x3555'u16
  check floatToHalf(65504.0f32) == 0x7BFF'u16
  check floatToHalf(Inf.float32) == 0x7C00'u16
  check floatToHalf(-Inf.float32) == 0xFC00'u16
  # denormals: m * 2^-24 exactly (a /1024 bug here once broke B44 tables)
  check halfToFloat(0x0001'u16) == 5.9604645e-8f32
  check halfToFloat(0x03FF'u16) == 1023.0f32 * 5.9604645e-8f32
  check halfToFloat(0x8401'u16) == -(1025.0f32 * 5.9604645e-8f32)

test "exr rgb32f round-trip (ZIP)":
  var px = @[Rgb[float32](data: [1.0f32, 0.5, 0.25]),
             Rgb[float32](data: [-2.0f32, 100.0, 0.0])]
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 2, height: 1, pixels: px))
  let enc = encodeExr(img)
  check enc.ok
  check enc.value[0] == 0x76 and enc.value[1] == 0x2F
  let dec = decodeExr(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb32F
  check dec.value.rgb32f.pixels == px

test "exr luma32f round-trip":
  var px = @[Luma[float32](data: [3.25f32])]
  let img = DynamicImage(kind: dkLuma32F, luma32f: Gray32FImage(width: 1, height: 1, pixels: px))
  let dec = decodeExr(encodeExr(img).value)
  check dec.ok
  check dec.value.luma32f.pixels == px

test "exr reference RLE":
  let dir = fixturesDir / "exr"
  var foundUncropped = false
  var foundCropped = false
  for kind, p in walkDir(dir):
    if not p.endsWith(".exr"): continue
    var f = open(p, fmRead)
    var raw = newSeq[uint8](getFileSize(f))
    discard readBytes(f, raw, 0, raw.len)
    close(f)
    let dec = decodeExr(raw)
    if p.contains("uncropped"):
      foundUncropped = true
      check dec.ok
      check dec.value.kind == dkRgba32F
      check dec.value.dimensions() == (1920'u32, 1920'u32)
      # pixel-content lock vs the reference decoder (5498 nonzero,
      # channel sum 11670.322387271794): guards the biased RLE predictor
      # and planar layout, which dimensions alone cannot catch.
      var nz = 0
      var sum = 0.0'f64
      for q in dec.value.rgba32f.pixels:
        if q.data[0] != 0 or q.data[1] != 0 or q.data[2] != 0: inc nz
        sum += q.data[0].float64 + q.data[1].float64 +
          q.data[2].float64 + q.data[3].float64
      check nz == 5498
      check abs(sum - 11670.322387271794'f64) < 1e-6
    elif p.contains("differs"):
      foundCropped = true
      check dec.ok
      check dec.value.kind == dkRgba32F
      # data window 1012..1326 x 1097..1196
      check dec.value.dimensions() == (315'u32, 100'u32)
  check foundUncropped and foundCropped

test "exr piz reference decodes":
  let p = fixturesDir / "exr" / "overexposed gradient - data window equals display window.exr"
  var f = open(p, fmRead)
  var raw = newSeq[uint8](getFileSize(f))
  discard readBytes(f, raw, 0, raw.len)
  close(f)
  let dec = decodeExr(raw)
  check dec.ok
  check dec.value.kind == dkRgba32F
  check dec.value.dimensions() == (20'u32, 12'u32)
  # spot values vs the reference decoder (bit-exact PIZ conformance)
  check dec.value.rgba32f.pixels[0].data ==
    [0.69149625f32, 0.18248774f32, 0.2710451f32, 1.0f32]
  check dec.value.rgba32f.pixels[1].data ==
    [0.75934595f32, 0.2371794f32, 0.31343064f32, 1.0f32]

test "exr pxr24 round-trip within spec error":
  # PXR24 rounds float channels to 24 bits (spec: rel err ~3e-5).
  var px = @[
    Rgb[float32](data: [1.0f32, 0.5f32, -0.25f32]),
    Rgb[float32](data: [100.0f32, -2.0f32, 0.0f32]),
    Rgb[float32](data: [1.0f32/3.0f32, 65504.0f32, 1e-7f32]),
    Rgb[float32](data: [Inf.float32, 0.0f32, -0.0f32])]
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 4, height: 1, pixels: px))
  let enc = encodeExr(img, 5)
  check enc.ok
  check enc.value[0] == 0x76 and enc.value[1] == 0x2F
  let dec = decodeExr(enc.value)
  check dec.ok
  check dec.value.kind == dkRgb32F
  for i, p in dec.value.rgb32f.pixels:
    for c in 0..2:
      let a = px[i].data[c]
      let b = p.data[c]
      if a != a or a == Inf.float32 or a == -Inf.float32:
        check b == a
      elif a == 0.0f32:
        check b == 0.0f32
      else:
        check abs(b - a) / abs(a) <= 3e-5f32

test "exr pxr24 official reference decodes bit-exact":
  # Fixtures written directly with the reference library (OpenEXR 3.4.12
  # C++ API, no CLI in the loop) from a 16x16 float gradient: the float
  # file must decode bit-identical to the reference lib's own PXR24->NONE
  # conversion of the same pixels (standard conformance: exact vs
  # reference decoder output, not vs pre-lossy original). NOTE: do not
  # mint these with `exrmetrics --convert` — its ZIP/RLE->PXR24 transcode
  # path emits non-planar chunks the reference decoder itself misreads.
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  let a = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-float.exr"))
  let b = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-float-none.exr"))
  check a.ok and b.ok
  check a.value.kind == dkRgb32F and b.value.kind == dkRgb32F
  check a.value.rgb32f.pixels == b.value.rgb32f.pixels
  # half channels survive PXR24 exactly: expected = half-rounded source
  let h = decodeExr(readRaw(fixturesDir / "exr" / "pxr24-reference-half.exr"))
  check h.ok
  check h.value.kind == dkRgb32F
  for y in 0..<16:
    for x in 0..<16:
      let fx = float32(x) / 15.0f32
      let fy = float32(y) / 15.0f32
      let src = [fx*100.0f32 - 50.0f32, fy*2.0f32 - 1.0f32, (fx+fy)*0.5f32]
      let got = h.value.rgb32f.pixels[y*16+x].data
      if x == 0 and y == 0:
        check got[0] == halfToFloat(floatToHalf(65504.0f32))
        check got[1] == halfToFloat(floatToHalf(-65504.0f32))
        check got[2] == halfToFloat(floatToHalf(1e-7f32))
      else:
        for c in 0..2:
          check got[c] == halfToFloat(floatToHalf(src[c]))

test "exr foreign lossless files decode bit-exact":
  # Same lib-minted pixels under NONE/RLE/ZIPS/ZIP must all decode to
  # identical pixels (covers the planar-per-scanline disk layout and the
  # biased ZIP/RLE predictor against foreign bytes, not just our own).
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  var refPx: seq[Rgb[float32]] = @[]
  for i, name in ["pxr24-lib-none.exr", "rle-lib-reference.exr",
      "zips-lib-reference.exr", "zip-lib-reference.exr"]:
    let d = decodeExr(readRaw(fixturesDir / "exr" / name))
    check d.ok
    check d.value.kind == dkRgb32F
    check d.value.dimensions() == (16'u32, 16'u32)
    if i == 0: refPx = d.value.rgb32f.pixels
    else: check d.value.rgb32f.pixels == refPx
  # anchor against the known source gradient (px0 extremes + a mid pixel)
  check refPx[0].data == [65504.0f32, -65504.0f32, 1e-7f32]
  let fx = float32(10) / 15.0f32
  check refPx[10].data[0] == fx*100.0f32 - 50.0f32
  check refPx[10].data[1] == -1.0f32

test "exr b44 tables match reference":
  # Spot anchors from OpenEXR's b44ExpLogTable (exact formula verified
  # over all 65536 entries during development): exp(x/8), 8*log(x).
  ensureB44Tables()
  check b44ExpTable[0x0000] == 0x3C00'u16 # exp(0) = 1
  check b44ExpTable[0x3C00] == 0x3C88'u16 # exp(1/8)
  check b44ExpTable[0x7BFF] == 0x7BFF'u16 # overflow clamps to HALF_MAX
  check b44ExpTable[0x7C00] == 0x0000'u16 # inf -> 0
  check b44LogTable[0x0000] == 0xFC00'u16 # 8*log(0) = -inf, preserved
  check b44LogTable[0x3C00] == 0x0000'u16 # 8*log(1) = 0
  check b44LogTable[0x4000] == 0x458C'u16 # 8*ln(2)
  check b44LogTable[0x7C00] == 0x0000'u16 # +inf -> 0
  check b44LogTable[0xBC00] == 0x0000'u16 # negatives -> 0

test "exr b44 pack/unpack round-trips":
  # Flat block (B44A short form + B44 long form agree after decode).
  var flat: array[16, uint16]
  for i in 0..<16: flat[i] = 0x3800'u16 # 0.5
  let p3 = b44Pack(flat, true, true)
  check p3.len == 3 and p3[2] == 0xFC'u8
  let p14 = b44Pack(flat, false, true)
  check p14.len == 14
  check b44Unpack(p3, true) == flat
  check b44Unpack(p14, false) == flat
  # NaN/Inf inputs are replaced with zeroes before packing.
  var special: array[16, uint16]
  for i in 0..<16: special[i] = 0x3C00'u16
  special[0] = 0x7C00'u16 # +inf
  special[1] = 0xFFFF'u16 # NaN
  let ps = b44Pack(special, false, true)
  let back = b44Unpack(ps, false)
  check back[0] == 0x0000'u16
  check back[1] == 0x0000'u16
  check back[2] == 0x3C00'u16

test "exr b44 official files decode bit-exact":
  # Fixtures minted with the reference library (C++ API): B44/B44A half
  # files (20x20 with flat region, extremes, inf/nan/denormal + 7x5 odd
  # sizes) must decode bit-identically to the reference lib's own
  # B44->NONE conversions. NaN compares unequal to itself, so compare
  # lanes with NaN-aware equality (payloads verified identical).
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  proc samePixels(a, b: seq[Rgb[float32]]): bool =
    if a.len != b.len: return false
    for i in 0..<a.len:
      for c in 0..2:
        let x = a[i].data[c]; let y = b[i].data[c]
        if x != x and y != y: continue
        if x != y: return false
    true
  for (cf, cn) in [("b44-reference-half.exr", "b44-reference-half-none.exr"),
      ("b44a-reference-half.exr", "b44a-reference-half-none.exr"),
      ("b44-reference-odd.exr", "b44-reference-odd-none.exr"),
      ("b44a-reference-odd.exr", "b44a-reference-odd-none.exr"),
      ("b44-reference-float.exr", "b44-reference-float-none.exr")]:
    let a = decodeExr(readRaw(fixturesDir / "exr" / cf))
    let b = decodeExr(readRaw(fixturesDir / "exr" / cn))
    check a.ok and b.ok
    check a.value.kind == dkRgb32F and b.value.kind == dkRgb32F
    check samePixels(a.value.rgb32f.pixels, b.value.rgb32f.pixels)

test "exr b44 encode float passes through losslessly":
  # Our writer emits float channels, which B44 stores uncompressed.
  var px = @[Rgb[float32](data: [1.0f32, 0.5f32, -0.25f32]),
             Rgb[float32](data: [100.0f32, -2.0f32, 65504.0f32])]
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 2, height: 1, pixels: px))
  for comp in [6, 7]:
    let enc = encodeExr(img, comp)
    check enc.ok
    let dec = decodeExr(enc.value)
    check dec.ok
    check dec.value.rgb32f.pixels == px

test "exr piz official files decode bit-exact":
  # Fixtures minted directly with the reference library (C++ API):
  # smooth 64x64 half/float (Huffman path) and 128x128 grainy half
  # (multi-chunk Huffman path), each with a lib-decoded NONE anchor.
  # NaN lanes compare by bit pattern (NaN != NaN by definition).
  proc readRaw(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  proc samePixels(a, b: seq[Rgb[float32]]): bool =
    if a.len != b.len: return false
    for i in 0..<a.len:
      for c in 0..2:
        let x = a[i].data[c]; let y = b[i].data[c]
        if x != x and y != y: continue
        if x != y: return false
    true
  for (cf, cn) in [("piz64s-reference-half.exr", "piz64s-reference-half-none.exr"),
      ("piz64s-reference-float.exr", "piz64s-reference-float-none.exr"),
      ("piz128-reference-half.exr", "piz128-reference-half-none.exr")]:
    let a = decodeExr(readRaw(fixturesDir / "exr" / cf))
    let b = decodeExr(readRaw(fixturesDir / "exr" / cn))
    check a.ok and b.ok
    check a.value.kind == dkRgb32F and b.value.kind == dkRgb32F
    check samePixels(a.value.rgb32f.pixels, b.value.rgb32f.pixels)

test "exr piz encode matches reference payloads":
  # Rebuild the smooth-64x64 source pixels in-test and verify our chunk
  # payloads are byte-identical to the reference library's (heap order,
  # canonical codes, table packing, RLE and bit packing all conform).
  proc chunkPayloads(raw: seq[uint8]): seq[seq[uint8]] =
    ## Raw chunk payloads in offset-table order (64 rows @ 32 = 2 chunks).
    var pos = 8
    while true:
      var e = pos
      while raw[e] != 0: inc e
      if e == pos: pos = e+1; break
      var e2 = e+1
      while raw[e2] != 0: inc e2
      let sz = int(uint32(raw[e2+1]) or (uint32(raw[e2+2]) shl 8) or
        (uint32(raw[e2+3]) shl 16) or (uint32(raw[e2+4]) shl 24))
      pos = e2+5+sz
    result = @[]
    for i in 0..<2:
      var off = 0'u64
      for b in 0..7: off = off or (uint64(raw[pos+i*8+b]) shl (8*b))
      let o = int(off)
      let psz = int(uint32(raw[o+4]) or (uint32(raw[o+5]) shl 8) or
        (uint32(raw[o+6]) shl 16) or (uint32(raw[o+7]) shl 24))
      result.add(raw[o+8 ..< o+8+psz])
  proc readRawFile(p: string): seq[uint8] =
    var f = open(p, fmRead)
    result = newSeq[uint8](getFileSize(f))
    discard readBytes(f, result, 0, result.len)
    close(f)
  var px = newSeq[Rgb[float32]](64*64)
  for y in 0..<64:
    for x in 0..<64:
      let fx = float32(x) / 63.0f32
      let fy = float32(y) / 63.0f32
      px[y*64+x] = Rgb[float32](data: [fx*2-1, fy*2-1, (fx+fy)*0.5f32])
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 64, height: 64, pixels: px))
  let enc = encodeExr(img, 4)
  check enc.ok
  let mine = chunkPayloads(enc.value)
  let refp = chunkPayloads(readRawFile(fixturesDir / "exr" / "piz64s-reference-float.exr"))
  check mine.len == refp.len
  for i in 0..<mine.len:
    check mine[i] == refp[i]

test "exr huffman codec round-trips":
  # Unit coverage for the PIZ entropy stage: skewed symbols (RLE path),
  # dense alphabet (multi-length codes) and flat input (single symbol).
  for data in [@[0'u16, 1, 0, 1, 0, 1, 2, 2, 2, 2, 2],
               @[5'u16, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 42],
               @[7'u16]]:
    var frq = newSeq[uint64](65537)
    for v in data: frq[int(v)] += 1
    var iMin, iMax: int
    let hcode = hufBuildEncTable(frq, iMin, iMax)
    let table = hufPackEncTable(hcode, iMin, iMax)
    let enc = hufEncode(hcode, data, iMax)
    check enc.nBits > 0
    var stream = newSeq[uint8](20 + table.len + (enc.nBits + 7) div 8)
    proc putU32(o, v: int) =
      stream[o] = uint8(v and 0xFF); stream[o+1] = uint8((v shr 8) and 0xFF)
      stream[o+2] = uint8((v shr 16) and 0xFF); stream[o+3] = uint8((v shr 24) and 0xFF)
    putU32(0, iMin); putU32(4, iMax); putU32(8, table.len)
    putU32(12, enc.nBits); putU32(16, 0)
    for i, b in table: stream[20 + i] = b
    for i, b in enc.bits: stream[20 + table.len + i] = b
    let dec = hufDecompress(stream, data.len)
    check dec.ok
    check dec.raw == data

test "exr piz round-trips losslessly":
  # Full pipeline self-check (wavelet + Huffman + bitmap + LUT).
  var px = newSeq[Rgb[float32]](16*16)
  for y in 0..<16:
    for x in 0..<16:
      px[y*16+x] = Rgb[float32](data: [float32(x)/15.0f32,
        float32(y)/15.0f32, 0.5f32])
  let img = DynamicImage(kind: dkRgb32F, rgb32f: Rgb32FImage(width: 16, height: 16, pixels: px))
  let enc = encodeExr(img, 4)
  check enc.ok
  let dec = decodeExr(enc.value)
  check dec.ok
  check dec.value.rgb32f.pixels == px
  # raw fallback path: uncompressed-size chunk passes through verbatim
  var planar = newSeq[uint8](4 * 1 * 12)
  for i in 0..<planar.len: planar[i] = uint8(i and 0xFF)
  var chs: seq[ExrChannel] = @[
    ExrChannel(name: "B", pixelType: 2, pLinear: false, xSamp: 1, ySamp: 1),
    ExrChannel(name: "G", pixelType: 2, pLinear: false, xSamp: 1, ySamp: 1),
    ExrChannel(name: "R", pixelType: 2, pLinear: false, xSamp: 1, ySamp: 1)]
  let u = pizUndoChunk(planar, 4, 1, chs, @[4, 4, 4])
  check u.ok
  check u.value == planar

test "exr bad magic":
  check decodeExr(@[0'u8, 1, 2, 3]).ok == false
