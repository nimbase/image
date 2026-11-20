## nview — photo gallery backed by the pure-Nim image library (macOS only).
##
## Usage: nview <image-or-directory>
##
## Native Cocoa window + toolbar ([prev] <name> [next]) and a Metal
## textured quad (aspect-fit letterbox). This file owns the gallery model
## and decoding; `nview_mac.m` owns the UI + Metal renderer. The two meet
## at the small C ABI below (galleryInit/Go/Current...).
##
## Decode covers every LDR format the library guesses (PNG, JPEG, GIF
## first frame, WebP, BMP, TIFF, TGA, PNM, ICO, QOI, HEIF); 16-bit/float
## sources (HDR, EXR, farbfeld) report a clear error, AVIF its stub.

when not defined(macosx):
  {.error: "nview gallery requires macOS (Cocoa + Metal)".}

{.compile: "nview_mac.m".}
{.passL: "-framework Cocoa -framework Metal -framework QuartzCore".}

import std/[os, strutils, algorithm, memfiles]
import image

proc nview_run() {.importc.}

const SupportedExts = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp",
  ".tif", ".tiff", ".tga", ".pnm", ".pbm", ".pgm", ".ppm", ".ico", ".qoi",
  ".heif", ".heic"]

var
  gallery: seq[string] = @[]
  galleryIdx = 0
  cached: RgbaImage
    ## Grow-only display pool shared across slides: `decodePathInto`
    ## blits into `cached.pixels` via `setLen` (capacity retained), and
    ## `galleryDropPixels` drops the length but keeps the backing, so a
    ## walk allocates the largest slide once instead of once per photo.
  cachedName = ""
  hasCache = false
  jpegScratch = initJpegScratch()
    ## Cross-navigation JPEG entropy buffer (Phase 2 S1): one gallery
    ## walk allocates the largest scan once instead of once per photo.
    ## Bit-identical output; the gallery is fixed per process launch,
    ## so no shrink discipline is needed here.
  pngScratch = initPngScratch()
    ## Cross-navigation PNG row buffers (Phase 2 S3), same terms.

proc decodeDyn(fmt: ImageFormat, bytes: openArray[uint8]): ImageResult[DynamicImage] =
  ## Dispatch for formats that decode straight to DynamicImage.
  ## Takes an openArray view (memfiles-friendly, zero-copy); the heif
  ## path copies once (other agent owns that decoder's seq API).
  case fmt
  of fmtPng: decodePng(bytes, pngScratch)
  of fmtJpeg: decodeJpeg(bytes, jpegScratch, 1)
  of fmtWebP: decodeWebp(bytes)
  of fmtBmp: decodeBmp(bytes)
  of fmtTiff: decodeTiff(bytes)
  of fmtTga: decodeTga(bytes)
  of fmtPnm: decodePnm(bytes)
  of fmtIco: decodeIco(bytes)
  of fmtHeif: decodeHeif(@bytes)
  of fmtAvif: decodeAvif(bytes) # v1 stub: returns Unsupported, message propagates
  of fmtGif, fmtQoi, fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(AssertionDefect, "decodeDyn: unexpected " & $fmt)

proc blitRgbaInto(dst: var RgbaImage, src: RgbaImage) =
  ## Copy `src` into `dst`, reusing `dst.pixels` capacity (grow-only
  ## pool). `setLen` keeps the backing when shrinking or regrowing
  ## within capacity, so a gallery walk allocates the largest slide
  ## once instead of once per photo. Fully overwritten, so no zeroing
  ## discipline needed beyond `setLen` itself.
  dst.width = src.width
  dst.height = src.height
  dst.pixels.setLen(src.pixels.len)
  if src.pixels.len > 0:
    copyMem(addr dst.pixels[0], unsafeAddr src.pixels[0],
      src.pixels.len * sizeof(Rgba[uint8]))

proc blitDynamicInto(dyn: DynamicImage, dst: var RgbaImage): bool =
  ## Convert `dyn` into `dst`, reusing `dst.pixels` capacity (same
  ## pool terms as `blitRgbaInto`). Returns false without touching
  ## `dst` for variants nview cannot display (16-bit/float stay an
  ## error at the call site). Only the 8-bit LDR kinds the gallery
  ## supports are handled, matching the old `toRgba8` coverage.
  case dyn.kind
  of dkRgba8:
    blitRgbaInto(dst, dyn.rgba8)
    true
  of dkRgb8:
    let s = dyn.rgb8
    dst.width = s.width
    dst.height = s.height
    dst.pixels.setLen(s.pixels.len)
    for i, p in s.pixels:
      dst.pixels[i] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2], 255'u8])
    true
  of dkLuma8:
    let s = dyn.luma8
    dst.width = s.width
    dst.height = s.height
    dst.pixels.setLen(s.pixels.len)
    for i, p in s.pixels:
      dst.pixels[i] = Rgba[uint8](data: [p.data[0], p.data[0], p.data[0], 255'u8])
    true
  else:
    false

const MaxDisplayPx* {.intdefine.} = 12_000_000
  ## Decode-resolution cap for display: JPEGs are decoded at the
  ## smallest denom whose output still covers this many pixels, so the
  ## GPU downscales from real detail. The denom box path is a cheap
  ## component-space filter (visibly worse than Preview even at 4x
  ## oversample: maxdiff 119 vs a proper downscale), while full-res
  ## decode costs ~0.04 s more on a 6.5 MP photo and downscales cleanly
  ## (maxdiff 10, zero pixels >10 vs fancy at 4x). A 32 MP photo lands
  ## at denom 2 (8 MP texture). Override with
  ## `-d:NviewMaxDisplayPx=<n>` to trade texture memory for sharpness.

proc displayDenom*(w, h: uint32): int =
  ## Smallest JPEG denom (1/2/4/8) whose output fits `MaxDisplayPx`.
  ## Pure function so the headless harness can pin the policy.
  result = 1
  var dw = uint64(w); var dh = uint64(h)
  while dw * dh > uint64(MaxDisplayPx) and result < 8:
    result *= 2
    dw = (dw + 1) div 2; dh = (dh + 1) div 2

proc decodePathInto(path: string, dst: var RgbaImage) =
  ## Decode `path` into `dst`, reusing `dst.pixels` capacity (grow-only
  ## display pool shared across slides). File bytes come from a
  ## read-only mmap view: zero heap copies (`heif` copies once
  ## internally — other agent owns that seq API). The mapping lives
  ## only for this call. Raises IOError on failure, leaving `dst`
  ## untouched (decode lands in temporaries; the pool is blitted only
  ## on success, so a failed slide keeps the old picture).
  var mf =
    try: memfiles.open(path)
    except OSError as e: raise newException(IOError, path & ": " & e.msg)
  defer: mf.close()
  if mf.size <= 0:
    raise newException(IOError, path & ": empty file")
  template view(): auto =
    cast[ptr UncheckedArray[uint8]](mf.mem).toOpenArray(0, mf.size - 1)
  let (found, fmt) = guessFormat(view())
  if not found:
    raise newException(IOError, "cannot guess format: " & path)
  case fmt
  of fmtGif:
    let r = gifFirstToRgba(view()) # v1: first frame only, no animation
    if not r.ok:
      raise newException(IOError, path & ": " & r.err.msg)
    blitRgbaInto(dst, r.value)
  of fmtQoi:
    let r = decodeQoi(view())
    if not r.ok:
      raise newException(IOError, path & ": " & r.err.msg)
    blitRgbaInto(dst, r.value)
  of fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(IOError, path & ": 16-bit/float input not supported in v1")
  of fmtJpeg:
    # Decode at (near-)full resolution: the denom box path is a cheap
    # component-space filter, visibly worse than Preview — the GPU
    # downscales from real detail instead. Only photos above
    # MaxDisplayPx step down (32 MP lands at denom 2, an 8 MP texture).
    var denom = 1
    let dd = jpegDimensions(view())
    if dd.ok:
      denom = displayDenom(dd.value.w, dd.value.h)
    let r = decodeJpeg(view(), jpegScratch, denom)
    if not r.ok:
      raise newException(IOError, path & ": " & r.err.msg)
    if not blitDynamicInto(r.value, dst):
      raise newException(IOError, path & ": unsupported pixel type in v1")
  else:
    let r = decodeDyn(fmt, view())
    if not r.ok:
      raise newException(IOError, path & ": " & r.err.msg)
    if not blitDynamicInto(r.value, dst):
      raise newException(IOError, path & ": unsupported pixel type in v1")

proc decodeBytes(raw: string, name: string): RgbaImage =
  ## Legacy string-content entry (kept for tests): copies once into an
  ## owned seq, then runs the same dispatch. Gallery uses decodePathInto.
  var bytes = newSeq[uint8](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  let (found, fmt) = guessFormat(bytes)
  if not found:
    raise newException(IOError, "cannot guess format: " & name)
  case fmt
  of fmtGif:
    let r = gifFirstToRgba(bytes)
    if not r.ok: raise newException(IOError, name & ": " & r.err.msg)
    return r.value
  of fmtQoi:
    let r = decodeQoi(bytes)
    if not r.ok: raise newException(IOError, name & ": " & r.err.msg)
    return r.value
  of fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(IOError, name & ": 16-bit/float input not supported in v1")
  of fmtJpeg:
    var denom = 1
    let dd = jpegDimensions(bytes)
    if dd.ok:
      denom = displayDenom(dd.value.w, dd.value.h)
    let r = decodeJpeg(bytes, jpegScratch, denom)
    if not r.ok: raise newException(IOError, name & ": " & r.err.msg)
    result = r.value.toRgba8()
    if result.width == 0 or result.height == 0:
      raise newException(IOError, name & ": unsupported pixel type in v1")
    return result
  else:
    let r = decodeDyn(fmt, bytes)
    if not r.ok: raise newException(IOError, name & ": " & r.err.msg)
    result = r.value.toRgba8()
    if result.width == 0 or result.height == 0:
      raise newException(IOError, name & ": unsupported pixel type in v1")

proc loadAt(idx: int): bool =
  ## Decode gallery[idx] into the shared display pool. Stays on the old
  ## image on error (`decodePathInto` only blits on success).
  let path = gallery[idx]
  try:
    decodePathInto(path, cached)
    cachedName = extractFilename(path)
    hasCache = true
    galleryIdx = idx
    true
  except IOError as e:
    stderr.writeLine("nview: " & e.msg)
    false

# --- C ABI used by nview_mac.m (all values valid until the next nav call) ---

proc galleryInit*(path: cstring): cint {.exportc.} =
  let p = $path
  var dir, start = ""
  if dirExists(p):
    dir = p
  elif fileExists(p):
    dir = parentDir(p)
    start = p
  else:
    stderr.writeLine("nview: no such file or directory: " & p)
    return 1
  for f in walkDir(dir):
    if f.kind != pcFile: continue
    if splitFile(f.path).ext.toLowerAscii() in SupportedExts:
      gallery.add(f.path)
  gallery.sort(system.cmp)
  if gallery.len == 0:
    stderr.writeLine("nview: no supported images in " & dir)
    return 1
  var idx = 0
  if start.len > 0:
    idx = gallery.find(start)
    if idx < 0: idx = 0
  if not loadAt(idx):
    return 1
  0

proc galleryCount*(): cint {.exportc.} = cint(gallery.len)
proc galleryIndex(): cint {.exportc.} = cint(galleryIdx)

proc galleryGo*(delta: cint): cint {.exportc.} =
  ## Move (wraps around); returns the new index, or -1 keeping the old
  ## image when the target fails to decode.
  if gallery.len == 0 or not hasCache: return -1
  let n = ((galleryIdx + int(delta)) mod gallery.len + gallery.len) mod gallery.len
  if loadAt(n): cint(n) else: -1

proc galleryCurrentName*(): cstring {.exportc.} = cstring(cachedName)

proc galleryCurrentPixels(w, h: ptr cint): pointer {.exportc.} =
  w[] = cint(cached.width)
  h[] = cint(cached.height)
  if cached.pixels.len == 0: return nil
  addr cached.pixels[0]

proc galleryDropPixels*() {.exportc.} =
  ## Drop the CPU length after the GPU has its copy, keeping the pool
  ## capacity for the next slide. The on-screen image lives in the Metal
  ## texture until the next upload; nothing reads `cached.pixels` in
  ## between (resize re-renders from the texture). `setLen(0)` retains
  ## the backing (unlike `= @[]`, which frees it), so a gallery walk
  ## allocates the largest slide once and reuses it. Width/height are
  ## kept (shape queries still answer; `galleryCurrentPixels` returns
  ## nil with no backing, and both upload call sites run only on a
  ## freshly decoded image).
  cached.pixels.setLen(0)

proc main() =
  if paramCount() < 1:
    stderr.writeLine("usage: nview <image-or-directory>")
    quit(1)
  if galleryInit(cstring(paramStr(1))) != 0:
    quit(1)
  nview_run()

when isMainModule:
  # Importing this module (e.g. a headless gallery-walk memory test)
  # gets the model + C ABI without launching the app.
  main()
