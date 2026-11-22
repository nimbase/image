## JPEG 2000: lossless 5/3 + RCT and HTJ2K decode (8/16-bit).
## Legacy fixtures generated with opj_compress v2.5.4 (`-n 3`, default
## lossless); HT fixtures with ojph_compress/ojph_expand. Oracle sums via
## opj_decompress PGX planes (legacy, exact) and ojph_expand (HT: lossless
## fixtures pixel-exact; lossy fixtures pinned with sums, differing from
## ojph output by float-vs-fixed rounding noise of at most 1 per sample).
import unittest
import std/os
import image

const fixturesDir = "tests" / "fixtures"

proc readRaw(p: string): seq[uint8] =
  var f = open(p, fmRead)
  defer: close(f)
  let n = getFileSize(f)
  var buf = newSeq[uint8](n)
  discard readBytes(f, buf, 0, n)
  buf

proc lumSum8(img: DynamicImage): uint64 =
  assert img.kind == dkLuma8
  for p in img.luma8.pixels: result += uint64(p.data[0])

proc rgbSum8(img: DynamicImage): uint64 =
  assert img.kind == dkRgb8
  for p in img.rgb8.pixels:
    result += uint64(p.data[0]) + uint64(p.data[1]) + uint64(p.data[2])

proc lumSum16(img: DynamicImage): uint64 =
  assert img.kind == dkLuma16
  for p in img.luma16.pixels: result += uint64(p.data[0])

proc rgbaSum8(img: DynamicImage): uint64 =
  assert img.kind == dkRgba8
  for p in img.rgba8.pixels:
    result += uint64(p.data[0]) + uint64(p.data[1]) + uint64(p.data[2]) +
      uint64(p.data[3])

test "j2k ht lossless color":
  # HTJ2K reversible 5/3 via ojph (`-reversible true -num_decomps 2`).
  # Pixel-exact vs ojph_expand.
  let raw = readRaw(fixturesDir / "j2k" / "ht32.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380928'u64

test "j2k ht lossy color":
  # HTJ2K irreversible 9/7 via ojph (default lossy, 5 decompositions).
  # Fixed-point IDWT matches ojph float output up to +-1 rounding noise.
  let raw = readRaw(fixturesDir / "j2k" / "h32.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380933'u64

test "j2k ht lossless 16-bit gray":
  let raw = readRaw(fixturesDir / "j2k" / "ht16.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkLuma16
  check dec.value.dimensions() == (32'u32, 32'u32)
  check lumSum16(dec.value) == 33521664'u64

test "j2k ht lossy 16-bit gray":
  let raw = readRaw(fixturesDir / "j2k" / "h16.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkLuma16
  check dec.value.dimensions() == (32'u32, 32'u32)
  check lumSum16(dec.value) == 33521674'u64

test "j2k ht multi-tile":
  # 2x2 tiles: reversible lossless (exact) and irreversible lossy
  # (ojph float-vs-fixed noise sums).
  for (name, want) in [("htt4l.j2k", 380928'u64), ("htl4.j2k", 380963'u64)]:
    let raw = readRaw(fixturesDir / "j2k" / name)
    let dec = decodeJ2kRaw(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (32'u32, 32'u32)
    check rgbSum8(dec.value) == want

test "j2k ht lossy jp2 container":
  let raw = readRaw(fixturesDir / "j2k" / "hc32.jp2")
  let dec = decodeJp2(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380981'u64

test "j2k ht user precincts":
  # Explicit precincts with HT code-blocks (per-precinct tag trees +
  # opj-compatible block clamping). Lossless, pixel-exact vs ojph_expand.
  let raw = readRaw(fixturesDir / "j2k" / "htprec.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380928'u64

test "j2k ht tiny blocks":
  # 8x8 single-block edge cases incl. all-zero input (z8), impulse (o8).
  for (name, want) in [("z8.j2k", 0'u64), ("o8.j2k", 200'u64),
      ("h8.j2k", 4480'u64)]:
    let raw = readRaw(fixturesDir / "j2k" / name)
    let dec = decodeJ2kRaw(raw)
    check dec.ok
    check dec.value.kind == dkLuma8
    check dec.value.dimensions() == (8'u32, 8'u32)
    check lumSum8(dec.value) == want

test "j2k lossless gray":
  let raw = readRaw(fixturesDir / "j2k" / "g32.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkLuma8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check lumSum8(dec.value) == 126976'u64

test "j2k lossless color with MCT":
  let raw = readRaw(fixturesDir / "j2k" / "c32.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380928'u64

test "j2k lossless 16-bit gray":
  let raw = readRaw(fixturesDir / "j2k" / "g16.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkLuma16
  check dec.value.dimensions() == (32'u32, 32'u32)
  check lumSum16(dec.value) == 33521664'u64

test "jp2 container gray + color":
  let g = decodeJp2(readRaw(fixturesDir / "j2k" / "g32.jp2"))
  check g.ok
  check g.value.kind == dkLuma8
  check lumSum8(g.value) == 126976'u64
  let c = decodeJp2(readRaw(fixturesDir / "j2k" / "c32.jp2"))
  check c.ok
  check c.value.kind == dkRgb8
  check rgbSum8(c.value) == 380928'u64

test "j2k rgba with alpha":
  for name in ["a4.j2k", "a4.jp2"]:
    let raw = readRaw(fixturesDir / "j2k" / name)
    let dec = decodeJp2(raw)
    check dec.ok
    check dec.value.kind == dkRgba8
    check dec.value.dimensions() == (16'u32, 16'u32)
    check rgbaSum8(dec.value) == 97920'u64

test "j2k multi-tile, progression, sop/eph, bypass":
  # t4: 2x2 tiles, D=1, MCT. pocl: RPCL progression order. sopeph:
  # SOP+EPH markers. byp: selective bypass (raw coding passes). All
  # encode the same 32x32 RGB gradient (oracle sums vs opj_decompress).
  for name in ["t4.j2k", "pocl.j2k", "sopeph.j2k", "byp.j2k"]:
    let raw = readRaw(fixturesDir / "j2k" / name)
    let dec = decodeJ2kRaw(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (32'u32, 32'u32)
    check rgbSum8(dec.value) == 380928'u64

test "j2k poc windows and multi-layer":
  # pocw: single POC window (CPRL over res 0..2, comps 0..3) in the
  # tile-part header (opj placement). ml: 2 quality layers with empty
  # symbol-less segments. Both encode the 32x32 RGB gradient losslessly.
  for name in ["pocw.j2k", "ml.j2k"]:
    let raw = readRaw(fixturesDir / "j2k" / name)
    let dec = decodeJ2kRaw(raw)
    check dec.ok
    check dec.value.kind == dkRgb8
    check dec.value.dimensions() == (32'u32, 32'u32)
    check rgbSum8(dec.value) == 380928'u64

test "j2k user precincts":
  # Explicit 8x8/16x16 precincts (opj -c). Code-blocks clamp to the
  # precinct grid and each precinct carries its own tag trees.
  # Lossless 32x32 RGB, oracle sum vs opj_decompress.
  let raw = readRaw(fixturesDir / "j2k" / "prec.j2k")
  let dec = decodeJ2kRaw(raw)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (32'u32, 32'u32)
  check rgbSum8(dec.value) == 380928'u64

test "j2k via decodeImage sniffing":
  check decodeImage(readRaw(fixturesDir / "j2k" / "g32.j2k")).ok
  check decodeImage(readRaw(fixturesDir / "j2k" / "g32.jp2")).ok

test "j2k framing from heif extractor":
  let heif = readRaw(fixturesDir / "heif" / "j2k-64x48.heif")
  let ex = extractJ2kCodestream(heif)
  check ex.ok
  check ex.value.len > 100
  # lossless 5/3 (trans=1) with 5 DWT levels: fully decodable.
  # Sums oracled against opj_decompress PGX planes (dwebp-style pinning).
  let dec = decodeJ2kRaw(ex.value)
  check dec.ok
  check dec.value.kind == dkRgb8
  check dec.value.dimensions() == (64'u32, 48'u32)
  var s = 0'u64
  for p in dec.value.rgb8.pixels:
    s += uint64(p.data[0]) + uint64(p.data[1]) + uint64(p.data[2])
  check s == 1176074'u64

test "j2k soc/siz required":
  check decodeJ2kRaw(@[]).ok == false
  check decodeJ2kRaw(@[0xFF'u8, 0x4F]).ok == false
  check decodeJ2kRaw(@[0x00'u8, 0x00, 0x00, 0x0C]).ok == false
  check decodeJ2kRaw(@[0xFF'u8, 0x4F, 0xFF, 0x51, 0x00, 0x2F,
    0x00, 0x00]).ok == false

test "j2k truncated fixtures fail cleanly":
  for name in ["g32.j2k", "c32.j2k", "g16.j2k", "t4.j2k", "pocl.j2k",
      "sopeph.j2k", "byp.j2k", "a4.j2k", "pocw.j2k", "ml.j2k",
      "prec.j2k", "ht32.j2k", "h32.j2k", "ht16.j2k", "h16.j2k",
      "htt4l.j2k", "htl4.j2k", "htprec.j2k", "z8.j2k", "o8.j2k",
      "h8.j2k"]:
    let full = readRaw(fixturesDir / "j2k" / name)
    check full.len > 20
    for c in [0, 1, 2, 4, 10, 40, 47, 60, full.len div 2, full.len - 1]:
      if c < full.len:
        check decodeJ2kRaw(full[0..<c]).ok == false
  for name in ["g32.jp2", "c32.jp2", "a4.jp2", "hc32.jp2"]:
    let full = readRaw(fixturesDir / "j2k" / name)
    for c in [0, 1, 2, 12, 85, full.len div 2, full.len - 1]:
      if c < full.len:
        check decodeJp2(full[0..<c]).ok == false

test "jp2 box framing":
  check decodeJp2(@[]).ok == false
  check decodeJp2(@[0x00'u8, 0x00, 0x00, 0x0C]).ok == false
  # raw codestream routes through decodeJp2
  let full = readRaw(fixturesDir / "j2k" / "g32.j2k")
  check decodeJp2(full).ok

test "jp2 sniffing":
  let (f1, g1) = guessFormat(@[0x00'u8, 0x00, 0x00, 0x0C, uint8('j'),
    uint8('P'), uint8(' '), uint8(' '), 13, 10, 0x87, 10])
  check f1
  check g1 == fmtJp2
  let (f2, g2) = guessFormat(@[0xFF'u8, 0x4F, 0xFF, 0x51])
  check f2
  check g2 == fmtJp2
