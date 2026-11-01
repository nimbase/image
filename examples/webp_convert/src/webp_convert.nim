## webp_convert — CLI: convert any supported image to WebP.
##
##   webp_convert input output [--quality N] [--lossless]
##
## Format is sniffed from magic bytes; first frame wins for animated /
## multi-image inputs; 16-bit and float sources auto-downconvert to 8-bit.
import std/os
import std/strutils
import std/strformat
import std/times
import image

const Usage = """usage: webp_convert input output [--quality N] [--lossless]

  input      any supported image (png jpeg gif bmp qoi pnm tga farbfeld
             tiff ico webp hdr exr heif)
  output     destination .webp path (overwritten)
  --quality N  lossy quality 1..100 (default 75)
  --lossless   VP8L lossless instead of lossy
  --help       print this message"""

proc fail(msg: string) {.noreturn.} =
  stderr.writeLine("webp_convert: " & msg)
  quit(1)

proc main() =
  var input = ""
  var output = ""
  var quality = 75
  var lossless = false
  var i = 1
  while i <= paramCount():
    let a = paramStr(i)
    case a
    of "--help", "-h":
      echo Usage
      quit(0)
    of "--lossless":
      lossless = true
    of "--quality", "-q":
      inc i
      if i > paramCount():
        fail("missing value for " & a)
      try:
        quality = parseInt(paramStr(i))
      except ValueError:
        fail("bad quality: " & paramStr(i))
    else:
      if a.startsWith("--"):
        fail("unknown flag: " & a & "\n" & Usage)
      elif input == "":
        input = a
      elif output == "":
        output = a
      else:
        fail("unexpected argument: " & a & "\n" & Usage)
    inc i
  if input == "" or output == "":
    fail(Usage)
  if quality < 1 or quality > 100:
    fail("quality out of range 1..100")

  var raw: string
  try:
    raw = readFile(input)
  except IOError as e:
    fail("cannot read " & input & ": " & e.msg)
  if raw.len == 0:
    fail("empty input: " & input)
  var data = newSeq[uint8](raw.len)
  if raw.len > 0:
    copyMem(addr data[0], unsafeAddr raw[0], raw.len)

  let t0 = cpuTime()
  let res = convertToWebp(data, quality = quality, lossless = lossless)
  if not res.ok:
    fail(res.err.msg)
  try:
    writeFile(output, cast[string](res.value))
  except IOError as e:
    fail("cannot write " & output & ": " & e.msg)
  let dt = cpuTime() - t0

  let dec = decodeImage(data) # must succeed: conversion just did
  let (w, h) = dec.value.dimensions()
  let mode = if lossless: "lossless"
    else: fmt"lossy q{quality}"
  echo fmt"{input} ({w}x{h}) -> {output} ({res.value.len} bytes, {mode}, {dt:.1f}s)"

when isMainModule:
  main()
