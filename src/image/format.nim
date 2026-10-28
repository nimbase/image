## ImageFormat mirroring references/image/src/io/format.rs
import std/os
import std/strutils
import ./error

type
  ImageFormat* = enum
    fmtPng
    fmtJpeg
    fmtGif
    fmtWebP
    fmtPnm
    fmtTiff
    fmtTga
    fmtBmp
    fmtIco
    fmtHdr
    fmtOpenExr
    fmtFarbfeld
    fmtAvif
    fmtQoi
    fmtHeif

func fromExtension*(ext: string): tuple[found: bool, f: ImageFormat] =
  let e = ext.toLowerAscii()
  case e
  of "avif": (true, fmtAvif)
  of "jpg", "jpeg", "jfif": (true, fmtJpeg)
  of "png", "apng": (true, fmtPng)
  of "gif": (true, fmtGif)
  of "webp": (true, fmtWebP)
  of "tif", "tiff": (true, fmtTiff)
  of "tga": (true, fmtTga)
  of "bmp": (true, fmtBmp)
  of "ico": (true, fmtIco)
  of "hdr": (true, fmtHdr)
  of "exr": (true, fmtOpenExr)
  of "pbm", "pam", "ppm", "pgm", "pnm": (true, fmtPnm)
  of "ff": (true, fmtFarbfeld)
  of "qoi": (true, fmtQoi)
  of "heif", "heic", "hif": (true, fmtHeif)
  else: (false, fmtPng)

func fromPath*(path: string): ImageResult[ImageFormat] =
  let ext = splitFile(path).ext
  if ext.len <= 1:
    return err[ImageFormat](paramError(pkGeneric, "no extension: " & path))
  let (found, f) = fromExtension(ext[1..^1])
  if found: ok(f)
  else: err[ImageFormat](unsupportedError(ukFormat, "unknown extension: " & ext))

func fromMimeType*(mime: string): tuple[found: bool, f: ImageFormat] =
  let m = mime.toLowerAscii()
  case m
  of "image/avif": (true, fmtAvif)
  of "image/jpeg": (true, fmtJpeg)
  of "image/png": (true, fmtPng)
  of "image/gif": (true, fmtGif)
  of "image/webp": (true, fmtWebP)
  of "image/tiff": (true, fmtTiff)
  of "image/x-targa", "image/x-tga": (true, fmtTga)
  of "image/bmp": (true, fmtBmp)
  of "image/x-icon", "image/vnd.microsoft.icon": (true, fmtIco)
  of "image/vnd.radiance": (true, fmtHdr)
  of "image/x-exr": (true, fmtOpenExr)
  of "image/x-portable-bitmap", "image/x-portable-graymap",
     "image/x-portable-pixmap", "image/x-portable-anymap": (true, fmtPnm)
  of "image/x-qoi": (true, fmtQoi)
  of "image/heif": (true, fmtHeif)
  of "image/heic": (true, fmtHeif)
  of "image/heif-sequence": (true, fmtHeif)
  else: (false, fmtPng)

func toMimeType*(f: ImageFormat): string =
  case f
  of fmtAvif: "image/avif"
  of fmtJpeg: "image/jpeg"
  of fmtPng: "image/png"
  of fmtGif: "image/gif"
  of fmtWebP: "image/webp"
  of fmtTiff: "image/tiff"
  of fmtTga: "image/x-targa"
  of fmtBmp: "image/bmp"
  of fmtIco: "image/x-icon"
  of fmtHdr: "image/vnd.radiance"
  of fmtOpenExr: "image/x-exr"
  of fmtPnm: "image/x-portable-anymap"
  of fmtQoi: "image/x-qoi"
  of fmtFarbfeld: "application/octet-stream"
  of fmtHeif: "image/heif"

func extensionsStr*(f: ImageFormat): seq[string] =
  case f
  of fmtPng: @["png"]
  of fmtJpeg: @["jpg", "jpeg"]
  of fmtGif: @["gif"]
  of fmtWebP: @["webp"]
  of fmtPnm: @["pbm", "pam", "ppm", "pgm", "pnm"]
  of fmtTiff: @["tiff", "tif"]
  of fmtTga: @["tga"]
  of fmtBmp: @["bmp"]
  of fmtIco: @["ico"]
  of fmtHdr: @["hdr"]
  of fmtOpenExr: @["exr"]
  of fmtFarbfeld: @["ff"]
  of fmtAvif: @["avif"]
  of fmtQoi: @["qoi"]
  of fmtHeif: @["heif", "heic", "hif"]

func allFormats*(): seq[ImageFormat] =
  @[fmtGif, fmtIco, fmtJpeg, fmtPng, fmtBmp, fmtTiff, fmtTga, fmtPnm,
    fmtFarbfeld, fmtAvif, fmtWebP, fmtOpenExr, fmtQoi, fmtHdr, fmtHeif]
