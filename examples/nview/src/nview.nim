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

import std/[os, strutils, algorithm]
import image

proc nview_run() {.importc.}

const SupportedExts = [".jpg", ".jpeg", ".png", ".gif", ".webp", ".bmp",
  ".tif", ".tiff", ".tga", ".pnm", ".pbm", ".pgm", ".ppm", ".ico", ".qoi",
  ".heif", ".heic"]

var
  gallery: seq[string] = @[]
  galleryIdx = 0
  cached: RgbaImage
  cachedName = ""
  hasCache = false
  jpegScratch = initJpegScratch()
    ## Cross-navigation JPEG entropy buffer (Phase 2 S1): one gallery
    ## walk allocates the largest scan once instead of once per photo.
    ## Bit-identical output; the gallery is fixed per process launch,
    ## so no shrink discipline is needed here.

proc decodeDyn(fmt: ImageFormat, bytes: seq[uint8]): ImageResult[DynamicImage] =
  ## Dispatch for formats that decode straight to DynamicImage.
  case fmt
  of fmtPng: decodePng(bytes)
  of fmtJpeg: decodeJpeg(bytes)
  of fmtWebP: decodeWebp(bytes)
  of fmtBmp: decodeBmp(bytes)
  of fmtTiff: decodeTiff(bytes)
  of fmtTga: decodeTga(bytes)
  of fmtPnm: decodePnm(bytes)
  of fmtIco: decodeIco(bytes)
  of fmtHeif: decodeHeif(bytes)
  of fmtAvif: decodeAvif(bytes) # v1 stub: returns Unsupported, message propagates
  of fmtGif, fmtQoi, fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(AssertionDefect, "decodeDyn: unexpected " & $fmt)

proc decodeBytes(raw: string, name: string): RgbaImage =
  ## Decode any supported file contents to RGBA8. Raises IOError on failure.
  var bytes = newSeq[uint8](raw.len)
  if raw.len > 0:
    copyMem(addr bytes[0], unsafeAddr raw[0], raw.len)
  let (found, fmt) = guessFormat(bytes)
  if not found:
    raise newException(IOError, "cannot guess format: " & name)
  case fmt
  of fmtGif:
    let r = gifFirstToRgba(bytes) # v1: first frame only, no animation
    if not r.ok:
      raise newException(IOError, name & ": " & r.err.msg)
    return r.value
  of fmtQoi:
    let r = decodeQoi(bytes)
    if not r.ok:
      raise newException(IOError, name & ": " & r.err.msg)
    return r.value
  of fmtHdr, fmtOpenExr, fmtFarbfeld:
    raise newException(IOError, name & ": 16-bit/float input not supported in v1")
  of fmtJpeg:
    # scaled decode for large photos: pick the largest denom that keeps
    # the image usable on screen (decode-time win for pixels the viewer
    # would downscale in GL anyway).
    var denom = 1
    let dd = jpegDimensions(bytes)
    if dd.ok:
      let m = max(dd.value.w, dd.value.h)
      if m > 2400: denom = 4
      elif m > 1200: denom = 2
    let r = decodeJpeg(bytes, jpegScratch, denom)
    if not r.ok:
      raise newException(IOError, name & ": " & r.err.msg)
    result = r.value.toRgba8()
    if result.width == 0 or result.height == 0:
      raise newException(IOError, name & ": unsupported pixel type in v1")
    return result
  else:
    let r = decodeDyn(fmt, bytes)
    if not r.ok:
      raise newException(IOError, name & ": " & r.err.msg)
    result = r.value.toRgba8()
    if result.width == 0 or result.height == 0:
      raise newException(IOError, name & ": unsupported pixel type in v1")

proc loadAt(idx: int): bool =
  ## Decode gallery[idx] into the cache. Stays on the old image on error.
  let path = gallery[idx]
  try:
    cached = decodeBytes(readFile(path), path)
    cachedName = extractFilename(path)
    hasCache = true
    galleryIdx = idx
    true
  except IOError as e:
    stderr.writeLine("nview: " & e.msg)
    false

# --- C ABI used by nview_mac.m (all values valid until the next nav call) ---

proc galleryInit(path: cstring): cint {.exportc.} =
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

proc galleryCount(): cint {.exportc.} = cint(gallery.len)
proc galleryIndex(): cint {.exportc.} = cint(galleryIdx)

proc galleryGo(delta: cint): cint {.exportc.} =
  ## Move (wraps around); returns the new index, or -1 keeping the old
  ## image when the target fails to decode.
  if gallery.len == 0 or not hasCache: return -1
  let n = ((galleryIdx + int(delta)) mod gallery.len + gallery.len) mod gallery.len
  if loadAt(n): cint(n) else: -1

proc galleryCurrentName(): cstring {.exportc.} = cstring(cachedName)

proc galleryCurrentPixels(w, h: ptr cint): pointer {.exportc.} =
  w[] = cint(cached.width)
  h[] = cint(cached.height)
  if cached.pixels.len == 0: return nil
  addr cached.pixels[0]

proc main() =
  if paramCount() < 1:
    stderr.writeLine("usage: nview <image-or-directory>")
    quit(1)
  if galleryInit(cstring(paramStr(1))) != 0:
    quit(1)
  nview_run()

main()
