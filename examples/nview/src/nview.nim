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

import std/[os, strutils, algorithm, memfiles, posix]
import image

proc nview_run() {.importc.}

const SupportedExts = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp",
  ".tif", ".tiff", ".tga", ".pnm", ".pbm", ".pgm", ".ppm", ".ico", ".qoi",
  ".heif", ".heic"]

var
  gallery: seq[string] = @[]
  galleryIdx = 0
  poolBase: pointer = nil
    ## OS-backed display buffer: mapped per slide at exact size,
    ## unmapped on GPU upload. Nim's allocator never returns freed heap
    ## to the OS, so a heap pool would pin one display image (128 MB at
    ## 32 MP) forever; an mmap'd buffer returns its pages deterministically
    ## while the Metal texture keeps the on-screen image. Same-size
    ## consecutive slides still fault the same pages with no heap churn.
  poolCapPx = 0
    ## Mapped capacity in pixels (always exactly the current image; the
    ## mapping lives only between decode and upload).
  poolW, poolH = 0
    ## Current image dims; 0 means empty (galleryCurrentPixels nil).
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

proc poolDrop() =
  ## Release the display mapping, returning its pages to the OS at once.
  ## Idempotent; safe to call with no mapping (failed decodes, startup).
  if poolBase != nil:
    discard munmap(poolBase, poolCapPx * sizeof(Rgba[uint8]))
    poolBase = nil
    poolCapPx = 0
  poolW = 0
  poolH = 0

proc poolTake(nPx: int): ptr UncheckedArray[Rgba[uint8]] =
  ## Map an exact-size RGBA display buffer. The mapping lives only
  ## between decode and upload; any previous mapping is released first
  ## (normal flow drops after every upload, so this is a no-op).
  if poolBase != nil: poolDrop()
  if nPx <= 0:
    raise newException(IOError, "nview: empty image")
  let bytes = nPx * sizeof(Rgba[uint8])
  poolBase = mmap(nil, bytes, PROT_READ or PROT_WRITE,
    MAP_PRIVATE or MAP_ANONYMOUS, -1, 0)
  if poolBase == cast[pointer](MAP_FAILED):
    poolBase = nil
    raise newException(OutOfMemDefect, "nview: display pool mmap failed")
  poolCapPx = nPx
  cast[ptr UncheckedArray[Rgba[uint8]]](poolBase)

proc blitRgbaInto(dst: ptr UncheckedArray[Rgba[uint8]], src: RgbaImage) =
  ## Copy `src` into the caller-sized pool slot. Fully overwritten.
  if src.pixels.len > 0:
    copyMem(addr dst[0], unsafeAddr src.pixels[0],
      src.pixels.len * sizeof(Rgba[uint8]))

proc blitDynamicInto(dyn: DynamicImage,
    dst: ptr UncheckedArray[Rgba[uint8]]): bool =
  ## Convert `dyn` into the caller-sized pool slot. Returns false
  ## without touching `dst` for variants nview cannot display
  ## (16-bit/float stay an error at the call site). Only the 8-bit LDR
  ## kinds the gallery supports are handled, matching `toRgba8`.
  case dyn.kind
  of dkRgba8:
    blitRgbaInto(dst, dyn.rgba8)
    true
  of dkRgb8:
    let s = dyn.rgb8
    for i, p in s.pixels:
      dst[i] = Rgba[uint8](data: [p.data[0], p.data[1], p.data[2], 255'u8])
    true
  of dkLuma8:
    let s = dyn.luma8
    for i, p in s.pixels:
      dst[i] = Rgba[uint8](data: [p.data[0], p.data[0], p.data[0], 255'u8])
    true
  else:
    false

proc decodePathInto(path: string) =
  ## Decode `path` into the OS-backed display pool (mapped at exact
  ## size for this call). File bytes come from a read-only mmap view:
  ## zero heap copies (`heif` copies once internally — other agent owns
  ## that seq API). JPEG decodes straight into the pool (no Rgb temp);
  ## other formats decode to a temp, then blit. The mapping lives only
  ## for this call. Raises IOError on failure with the pool released,
  ## so a failed slide keeps the old picture (which lives on in the
  ## Metal texture).
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
  template fail(msg: string) =
    poolDrop()
    raise newException(IOError, path & ": " & msg)
  case fmt
  of fmtGif:
    let r = gifFirstToRgba(view()) # v1: first frame only, no animation
    if not r.ok: fail(r.err.msg)
    let dst = poolTake(r.value.pixels.len)
    blitRgbaInto(dst, r.value)
    poolW = int(r.value.width)
    poolH = int(r.value.height)
  of fmtQoi:
    let r = decodeQoi(view())
    if not r.ok: fail(r.err.msg)
    let dst = poolTake(r.value.pixels.len)
    blitRgbaInto(dst, r.value)
    poolW = int(r.value.width)
    poolH = int(r.value.height)
  of fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(IOError, path & ": 16-bit/float input not supported in v1")
  of fmtJpeg:
    # Always full resolution, straight into the pool: the denom box
    # path is a cheap component-space filter, visibly worse than
    # Preview — the GPU downscales from real detail instead.
    let dd = jpegDimensions(view())
    if not dd.ok: fail(dd.err.msg)
    let nPx = int(dd.value.w) * int(dd.value.h)
    let dst = poolTake(nPx)
    let r = decodeJpegRgbaInto(view(), jpegScratch, dst, nPx, 1)
    if not r.ok:
      if r.err.kind == ekUnsupported:
        # 4-component (CMYK/YCCK): temp + convert fallback. Rare;
        # the temp is transient heap (arenas may retain it).
        poolDrop()
        let t = decodeJpeg(view(), jpegScratch, 1)
        if not t.ok: fail(t.err.msg)
        let d2 = t.value.toRgba8()
        if d2.width == 0 or d2.height == 0: fail("unsupported pixel type in v1")
        let dst2 = poolTake(d2.pixels.len)
        blitRgbaInto(dst2, d2)
        poolW = int(d2.width)
        poolH = int(d2.height)
      else:
        fail(r.err.msg)
    else:
      poolW = r.value.w
      poolH = r.value.h
  else:
    let r = decodeDyn(fmt, view())
    if not r.ok: fail(r.err.msg)
    # Size the pool from the decoded dims before touching it; the
    # convert only runs on success, so failure leaves nothing mapped.
    let (dw, dh) = r.value.dimensions()
    let dst = poolTake(int(dw) * int(dh))
    if not blitDynamicInto(r.value, dst):
      fail("unsupported pixel type in v1")
    poolW = int(dw)
    poolH = int(dh)

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
    let r = decodeJpeg(bytes, jpegScratch, 1)
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
  ## Decode gallery[idx] into the display pool. Stays on the old image
  ## on error (`decodePathInto` releases the pool on failure; the old
  ## picture lives on in the Metal texture).
  let path = gallery[idx]
  try:
    decodePathInto(path)
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
  w[] = cint(poolW)
  h[] = cint(poolH)
  if poolBase == nil or poolW <= 0 or poolH <= 0: return nil
  poolBase

proc galleryDropPixels*() {.exportc.} =
  ## Release the display mapping after the GPU has its copy: pages go
  ## back to the OS at once (munmap — Nim heap never returns pages, so
  ## a heap pool would pin one display image, 128 MB at 32 MP, forever).
  ## The on-screen image lives in the Metal texture until the next
  ## upload; nothing reads the pool in between (resize re-renders from
  ## the texture). The next `loadAt` maps a fresh exact-size buffer, so
  ## steady state holds no CPU pixels at all. Idempotent.
  poolDrop()

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
