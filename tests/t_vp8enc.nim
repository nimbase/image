import unittest
import std/math
import image
import image/codecs/webp
import image/codecs/vp8
import image/codecs/vp8tables
import image/codecs/vp8enc
import image/codecs/jpeg

proc flatGray(w, h: int, v: uint8): RgbaImage =
  var px = newSeq[Rgba[uint8]](w * h)
  for i in 0..<w*h:
    px[i] = Rgba[uint8](data: [v, v, v, 255])
  RgbaImage(width: uint32(w), height: uint32(h), pixels: px)

proc gradRgb(w, h: int): RgbaImage =
  var px = newSeq[Rgba[uint8]](w * h)
  for y in 0..<h:
    for x in 0..<w:
      px[y * w + x] = Rgba[uint8](data: [uint8((x * 7) mod 256),
        uint8((y * 11) mod 256), uint8(((x + y) * 5) mod 256), 255])
  RgbaImage(width: uint32(w), height: uint32(h), pixels: px)

proc yOf(p: Rgba[uint8]): int =
  let (yy, _, _) = rgbToYuv601(p.data[0], p.data[1], p.data[2])
  int(yy)

test "vp8 bool codec round-trips incl. extreme probs":
  var seed = 0x12345678'u64
  proc rnd(n: uint32): uint32 =
    seed = seed * 6364136223846793005'u64 + 1442695040886403407'u64
    uint32((seed shr 33) mod uint64(n))
  for trial in 0..<10:
    var e = initBoolEnc()
    var bits: seq[bool] = @[]
    var probs: seq[uint8] = @[]
    let n = 1 + int(rnd(300))
    for _ in 0..<n:
      # bias toward extremes to stress carry paths
      let p = [0'u8, 1, 128, 254, 255, uint8(rnd(256))][int(rnd(6))]
      let b = rnd(100) < 50
      bits.add(b)
      probs.add(p)
      putBit(e, b, p)
    e.flush()
    var d = initBoolDec(e.buf)
    for i in 0..<n:
      require d.readBit(probs[i]) == bits[i]

test "vp8 lossy flat round-trips near-exact at q100":
  let img = flatGray(16, 16, 120)
  let f = encodeVp8Lossy(img, 100)
  require f.ok
  let d = decodeVp8Frame(f.value)
  require d.ok
  check d.value.width == 16 and d.value.height == 16
  for y in 0..<16:
    for x in 0..<16:
      check abs(int(d.value.ybuf[y * 16 + x]) - yOf(img.pixels[0])) <= 2

test "vp8 lossy quality curve is sane":
  let img = gradRgb(48, 32)
  var srcY = newSeq[uint8](48 * 32)
  for i in 0..<48*32:
    srcY[i] = uint8(yOf(img.pixels[i]))
  var prevMse = -1.0
  for q in [90, 75, 50]:
    let f = encodeVp8Lossy(img, q)
    require f.ok
    let d = decodeVp8Frame(f.value)
    require d.ok
    var se = 0.0
    for i in 0..<48*32:
      let e = float(int(d.value.ybuf[i]) - int(srcY[i]))
      se += e * e
    let mse = se / float(48 * 32)
    let psnr = 10.0 * log10(65025.0 / max(mse, 1e-9))
    check psnr > 24.0 # v1 heuristic encoder clears this easily
    if prevMse >= 0:
      check mse >= prevMse # distortion grows as quality drops
    prevMse = mse

test "vp8 lossy deterministic":
  let img = gradRgb(20, 12)
  let a = encodeVp8Lossy(img, 75)
  let b = encodeVp8Lossy(img, 75)
  require a.ok
  require b.ok
  check a.value == b.value

test "vp8 lossy odd dimensions":
  for (w, h) in [(20, 12), (13, 7), (1, 1), (17, 16)]:
    let img = gradRgb(w, h)
    let f = encodeVp8Lossy(img, 75)
    require f.ok
    let d = decodeVp8Frame(f.value)
    require d.ok
    check d.value.width == w and d.value.height == h

test "vp8 lossy rejects bad input":
  let img = RgbaImage(width: 0, height: 0, pixels: @[])
  check encodeVp8Lossy(img, 75).ok == false
  check encodeVp8Lossy(flatGray(4, 4, 0), 0).ok == false
  check encodeVp8Lossy(flatGray(4, 4, 0), 101).ok == false
  check encodeVp8Lossy(flatGray(4, 4, 0), -1).ok == false

test "vp8 token writer matches decoder trees":
  # every token + extra + sign round-trips through the decoder's
  # own tree nodes and probability tables
  for plane in 0..<4:
    for band in 0..<8:
      for cx in 0..<3:
        let nodes = buildNodes(DctTokenTree, CoeffProbs[plane][band][cx])
        for start in [0, 1]:
          for tok in 0..10: # 11 = EOB, no payload
            if start == 1 and tok == 11: continue
            for extra in [0, 1, 3]:
              for neg in [false, true]:
                var e = initBoolEnc()
                writeToken(e, start, plane, band, cx, tok)
                var ci = -1
                if tok >= 5:
                  ci = tok - 5
                  var nb = 0
                  for t in ProbDctCat[ci]:
                    if t == 0: break
                    inc nb
                  if extra >= (1 shl nb): continue
                  writeExtra(e, ci, extra)
                  putFlag(e, neg)
                elif tok in 1..4:
                  putFlag(e, neg)
                e.flush()
                var d = initBoolDec(e.buf)
                require readWithTree(d, nodes, start) == int8(tok)
                if tok >= 5:
                  var ex = 0
                  for t in ProbDctCat[ci]:
                    if t == 0: break
                    ex = ex * 2 + (if readBit(d, t): 1 else: 0)
                  require ex == extra
                  require readFlag(d) == neg

test "vp8 rdo bit costs follow the bool coder":
  # prob/256 = P(0): the 0-branch gets a range*prob/256 split. Inverted
  # costs silently mislead RDO (found as dominated size/PSNR on the
  # photo matrix: bigger files with lower PSNR at every quality).
  check abs(bitCost(128, false) - 1.0) < 1e-9
  check abs(bitCost(128, true) - 1.0) < 1e-9
  check bitCost(1, false) > 7.0
  check bitCost(1, true) < 0.1
  check bitCost(255, false) < 0.1
  check bitCost(255, true) > 7.0
  # cost grows as probability shrinks
  check bitCost(64, false) > bitCost(192, false)
  check bitCost(64, true) < bitCost(192, true)

test "vp8 lossy low-quality photo crop round-trips":
  # Regression: cross-MB predictor/context state must mirror the decoder
  # exactly. Verified to fail ("truncated VP8 bitstream") when the
  # non-split topBpred publish is removed: RDO splits below non-split
  # rows select Bpred trees from stale contexts and desync the stream.
  # Real photo content at low quality exercises split/skip interactions
  # (including skipped splits, whose Y2-slot handling must also mirror
  # the decoder) far better than synthetics.
  var jf = open("tests/fixtures/pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg",
    fmRead)
  var raw = newSeq[uint8](getFileSize(jf))
  discard readBytes(jf, raw, 0, raw.len)
  close(jf)
  let dj = decodeJpeg(raw)
  require dj.ok
  let c = cropImage(dj.value, 100, 100, 512, 512)
  require c.ok
  let rgba = c.value.toRgba8()
  let f = encodeVp8Lossy(rgba, 50)
  require f.ok
  let d = decodeVp8Frame(f.value)
  require d.ok
  check d.value.width == 512 and d.value.height == 512
  var se = 0.0
  for i in 0..<rgba.pixels.len:
    let (yy, _, _) = rgbToYuv601(rgba.pixels[i].data[0],
      rgba.pixels[i].data[1], rgba.pixels[i].data[2])
    let e = float(int(d.value.ybuf[i]) - int(yy))
    se += e * e
  let psnr = 10.0 * log10(65025.0 / max(se / float(rgba.pixels.len), 1e-9))
  check psnr > 35.0

test "vp8 trellis keeps base levels at zero lambda":
  # With no rate penalty the DP must pick nearest-level everywhere
  # (EOB only drops all-zero tails, which emit identically).
  var s = 0x9E3779B9'u32
  proc rnd(): float64 =
    s = s * 1664525'u32 + 1013904223'u32
    float64(s) / 4294967296.0
  for _ in 0..<20:
    var F: array[16, float64]
    for k in 0..<16: F[k] = (rnd() - 0.5) * 4000.0
    for (plane, first) in [(0, 1), (2, 0), (3, 0)]:
      let (tq, tnz) = trellisBlk(F, 34'i16, 34'i16, plane, 1, first, 0.0)
      var bnz = false
      for k in 0..<16:
        let e = if k == 0 and first == 1: 0'i32
          else: quantizeCoeff(F[k] * 2.0, 34'i16)
        check tq[k] == e
        if e != 0: bnz = true
      check tnz == bnz

test "vp8 trellis never regresses block cost":
  # The DP minimizes D + lambdaT*R over a set containing base levels,
  # so honest block cost (transform distortion + token path rate via
  # the same tables the writer uses) must not exceed base cost.
  # Catches cost-model bugs (e.g. EOB terminals that drop tail
  # distortion make EOB look free and nuke real coefficients).
  var s = 0x1234567'u32
  proc rnd(): float64 =
    s = s * 1664525'u32 + 1013904223'u32
    float64(s) / 4294967296.0
  for _ in 0..<30:
    var F: array[16, float64]
    for k in 0..<16: F[k] = (rnd() - 0.5) * 4000.0
    for (plane, first, qi) in [(0, 1, 34), (2, 0, 40), (3, 0, 50)]:
      let q = int16(qi)
      let lamT = trellisLambda(0.01 * float64(q) * float64(q))
      let (tq, _) = trellisBlk(F, q, q, plane, 1, first, lamT)
      var bq: array[16, int32]
      for k in 0..<16:
        bq[k] = if k == 0 and first == 1: 0'i32
          else: quantizeCoeff(F[k] * 2.0, q)
      proc blkCost(qq: array[16, int32]): float64 =
        var dd = 0.0
        for k in 0..<16:
          let d = F[k] * 2.0 - float64(qq[k]) * float64(q)
          dd += d * d
        let (r, _) = coeffBlockRate(qq, plane, 1, first)
        dd + lamT * r
      check blkCost(tq) <= blkCost(bq) + 1e-6

test "vp8 adaptive token probs fire and round-trip":
  # Mixed content skews token usage away from defaults; the two-pass
  # encoder must install updates (vp8LastNumUpdates > 0) and the
  # resulting stream must decode exactly (our decoder; dwebp cross
  # checked on larger matrices).
  var px = newSeq[Rgba[uint8]](128 * 128)
  for y in 0..<128:
    for x in 0..<128:
      var r, g, b: uint8
      if x < 64 and y < 64:
        r = 200; g = 30; b = 30
      elif x >= 64 and y < 64:
        r = uint8(x mod 256); g = uint8(y mod 256)
        b = uint8((x + y) mod 256)
      elif x < 64:
        let v = if ((x div 4) + (y div 4)) mod 2 == 0: 20'u8 else: 230'u8
        r = v; g = v; b = v
      else:
        let v = if x - 64 > y - 64: 250'u8 else: 10'u8
        r = v; g = v; b = uint8((x mod 64) + 128)
      px[y * 128 + x] = Rgba[uint8](data: [r, g, b, 255])
  let img = RgbaImage(width: 128, height: 128, pixels: px)
  let f = encodeVp8Lossy(img, 75)
  require f.ok
  check vp8LastNumUpdates > 0
  let d = decodeVp8Frame(f.value)
  require d.ok
  check d.value.width == 128 and d.value.height == 128
