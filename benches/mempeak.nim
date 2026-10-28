## Peak-memory benchmark harness (plan: memory task).
## One case per process so ru_maxrss is attributable. Run with:
##   clue build benches/mempeak.nim --release -o:/tmp/mempeak
##   for c in jpgprog24 jpgsmall png1080 webp640 gifanim enc24 enc24opt convert24; do /tmp/mempeak $c; done
## ru_maxrss is process peak RSS (bytes on macOS, KB on Linux).
import std/[times, os, strformat, posix]
import image

proc peakMb(): float64 =
  var ru: Rusage
  discard getrusage(RUSAGE_SELF, addr ru)
  when defined(macosx):
    float64(ru.ru_maxrss) / 1e6
  else:
    float64(ru.ru_maxrss) / 1e3

proc readBytes(path: string): seq[uint8] =
  let s = readFile(path)
  result = newSeq[uint8](s.len)
  if s.len > 0:
    copyMem(addr result[0], unsafeAddr s[0], s.len)

proc readProf(name: string): seq[uint8] =
  ## Profiling decode fixtures live in /tmp (see benches/genjpgprof.nim).
  let path = "/tmp/jpgprof/" & name
  if not fileExists(path):
    quit("missing fixture " & path & "; run: clue build benches/genjpgprof.nim --release -o:/tmp/genjpgprof && /tmp/genjpgprof", 1)
  readBytes(path)

proc gradRgb(w, h: int): seq[Rgb[uint8]] =
  result = newSeq[Rgb[uint8]](w * h)
  for y in 0..<h:
    for x in 0..<w:
      result[y * w + x] = Rgb[uint8](data: [uint8((x * 255) div w),
        uint8((y * 255) div h), uint8(((x + y) * 255) div (w + h))])

proc report(caseName: string, info: string, t0: float64) =
  let pk = peakMb()
  let el = cpuTime() - t0
  # Steady live set after transient buffers are released (munmap'd JPEG
  # grids don't count here; GC freelists do NOT — occupied is live only).
  GC_fullCollect()
  echo fmt"{caseName} {info} elapsed={el:.1f}s peak={pk:.1f}MB steadyLive={float64(getOccupiedMem())/1e6:.1f}MB"

when isMainModule:
  let c = paramStr(1)
  var t0 = cpuTime()
  case c
  of "jpgprog24":
    let px = readBytes("tests/fixtures/pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgsmall":
    let px = readBytes("tests/fixtures/jpg/iptc.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "pnggen":
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 1920,
      height: 1080, pixels: gradRgb(1920, 1080)))
    let enc = encodePng(img)
    doAssert enc.ok, enc.err.msg
    writeFile("/tmp/t1080.png", cast[string](enc.value))
    report(c, "pngBytes=" & $enc.value.len, t0)
  of "png24enc":
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: gradRgb(6000, 4000)))
    let enc = encodePng(img)
    doAssert enc.ok, enc.err.msg
    writeFile("/tmp/t24.png", cast[string](enc.value))
    report(c, "pngBytes=" & $enc.value.len, t0)
  of "png24dec":
    let s = readFile("/tmp/t24.png")
    var data = newSeq[uint8](s.len)
    copyMem(addr data[0], unsafeAddr s[0], s.len)
    let dec = decodePng(data)
    doAssert dec.ok, dec.err.msg
    report(c, $dec.value.dimensions() & " pngBytes=" & $data.len, t0)
  of "png1080dec":
    let s = readFile("/tmp/t1080.png")
    var data = newSeq[uint8](s.len)
    copyMem(addr data[0], unsafeAddr s[0], s.len)
    let dec = decodePng(data)
    doAssert dec.ok, dec.err.msg
    report(c, $dec.value.dimensions() & " pngBytes=" & $data.len, t0)
  of "webp640":
    let px = readBytes("tests/fixtures/webp/lossy_images/photo-640x427-q75.webp")
    let r = decodeWebp(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "gifanim":
    var frames: seq[seq[uint8]] = @[]
    for f in 0..<8:
      var fr = newSeq[uint8](320 * 240)
      for i in 0..<fr.len: fr[i] = uint8((i + f * 37) and 0x03)
      frames.add(fr)
    let pal = @[(r: 0'u8, g: 0'u8, b: 0'u8), (r: 255'u8, g: 0'u8, b: 0'u8),
      (r: 0'u8, g: 255'u8, b: 0'u8), (r: 0'u8, g: 0'u8, b: 255'u8)]
    let enc = encodeGif(frames, 320, 240, pal)
    let dec = decodeGif(enc)
    doAssert dec.ok, dec.err.msg
    report(c, "frames=" & $dec.value.frames.len & " gifBytes=" & $enc.len, t0)
  of "synth24":
    var px = gradRgb(6000, 4000)
    doAssert px.len == 6000 * 4000
    report(c, "pxBytes=" & $(px.len * 3), t0)
  of "enc24":
    var px = gradRgb(6000, 4000)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: move(px)))
    let enc = encodeJpeg(img, 90)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "enc24opt":
    var px = gradRgb(6000, 4000)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: move(px)))
    let enc = encodeJpeg(img, 90, optimize = true)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "convert24":
    let px = readBytes("tests/fixtures/pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    let rgba = r.value.toRgba8()
    doAssert rgba.width > 0
    report(c, $r.value.dimensions() & " rgbaBytes=" & $(rgba.pixels.len * 4), t0)
  of "jpgbase24":
    let px = readProf("base24.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgbase24d4":
    let px = readProf("base24.jpg")
    let r = decodeJpeg(px, 4)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpggray24":
    let px = readProf("gray24.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpg444":
    let px = readProf("c444_24.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgodd":
    let px = readProf("odd.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgprog24d4":
    let px = readBytes("tests/fixtures/pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg")
    let r = decodeJpeg(px, 4)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgprog24d8":
    let px = readBytes("tests/fixtures/pawel-czerwinski-dz4Kpq_8xRg-unsplash.jpg")
    let r = decodeJpeg(px, 8)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgprogsmall":
    let px = readBytes("tests/fixtures/jpg/progressive/cat.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgphone15":
    let px = readBytes("tests/fixtures/img20250220_18534209.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgphone15d4":
    let px = readBytes("tests/fixtures/img20250220_18534209.jpg")
    let r = decodeJpeg(px, 4)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgphone139":
    let px = readBytes("tests/fixtures/img20250218_20360309.jpg")
    let r = decodeJpeg(px)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgphone139d4":
    let px = readBytes("tests/fixtures/img20250218_20360309.jpg")
    let r = decodeJpeg(px, 4)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "jpgphone139d8":
    let px = readBytes("tests/fixtures/img20250218_20360309.jpg")
    let r = decodeJpeg(px, 8)
    doAssert r.ok, r.err.msg
    report(c, $r.value.dimensions() & " in=" & $px.len, t0)
  of "enc24q75":
    var px = gradRgb(6000, 4000)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: move(px)))
    let enc = encodeJpeg(img, 75)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "enc24q95":
    var px = gradRgb(6000, 4000)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: move(px)))
    let enc = encodeJpeg(img, 95)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "enc24nosub":
    var px = gradRgb(6000, 4000)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6000,
      height: 4000, pixels: move(px)))
    let enc = encodeJpeg(img, 90, subsample = false)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "enc24gray":
    var gx = newSeq[Luma[uint8]](6000 * 4000)
    for i in 0..<gx.len: gx[i] = Luma[uint8](data: [uint8(i mod 251)])
    let img = DynamicImage(kind: dkLuma8,
      luma8: GrayImage(width: 6000, height: 4000, pixels: move(gx)))
    let enc = encodeJpeg(img, 90)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  of "encodd":
    var ox = gradRgb(6017, 4023)
    let img = DynamicImage(kind: dkRgb8, rgb8: RgbImage(width: 6017,
      height: 4023, pixels: move(ox)))
    let enc = encodeJpeg(img, 90)
    doAssert enc.ok, enc.err.msg
    report(c, "out=" & $enc.value.len, t0)
  else:
    quit("unknown case: " & c, 1)
