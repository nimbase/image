## nview — minimal photo viewer backed by the pure-Nim image library.
##
## Usage: nview photo.png
##
## Decode covers every LDR format the library guesses (PNG, JPEG, GIF,
## WebP, BMP, TIFF, TGA, PNM, ICO, QOI, HEIF); display is a windy window
## with an OpenGL 4.1 textured quad, aspect-fit letterboxed.
## Drop a file onto the window to switch images. Esc/Q quits.

import std/[os, strutils]
import opengl, vmath, windy
import image

const
  MaxWinW = 1280.0
  MaxWinH = 800.0

  vertexSrc = """
#version 410
in vec3 vertexPos;
in vec2 vertexUv;
out vec2 uv;
void main() {
  uv = vertexUv;
  gl_Position = vec4(vertexPos, 1.0);
}
"""

  fragmentSrc = """
#version 410
in vec2 uv;
uniform sampler2D tex;
out vec4 fragColor;
void main() {
  fragColor = texture(tex, uv);
}
"""

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
    let r = decodeJpeg(bytes, denom)
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

proc compileShader(kind: GLenum, src: string): GLuint =
  result = glCreateShader(kind)
  let arr = allocCStringArray([src])
  glShaderSource(result, 1, arr, nil)
  deallocCStringArray(arr)
  glCompileShader(result)
  var code: GLint
  glGetShaderiv(result, GL_COMPILE_STATUS, addr code)
  if code == 0:
    var len: GLint
    glGetShaderiv(result, GL_INFO_LOG_LENGTH, addr len)
    var log = newString(len)
    glGetShaderInfoLog(result, len, nil, log.cstring)
    raise newException(IOError, "shader compile failed: " & log)

proc linkProgram(vs, fs: GLuint): GLuint =
  result = glCreateProgram()
  glAttachShader(result, vs)
  glAttachShader(result, fs)
  glLinkProgram(result)
  var code: GLint
  glGetProgramiv(result, GL_LINK_STATUS, addr code)
  if code == 0:
    var len: GLint
    glGetProgramiv(result, GL_INFO_LOG_LENGTH, addr len)
    var log = newString(len)
    glGetProgramInfoLog(result, len, nil, log.cstring)
    raise newException(IOError, "shader link failed: " & log)

proc upload(tex: GLuint, img: RgbaImage) =
  ## Push RGBA8 top-down pixels into the GL texture (reallocates on resize).
  ## UVs are flipped (see quad data) so the first row lands at the top.
  glBindTexture(GL_TEXTURE_2D, tex)
  glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8.GLint,
    img.width.GLsizei, img.height.GLsizei, 0,
    GL_RGBA, GL_UNSIGNED_BYTE, unsafeAddr img.pixels[0])
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE)
  glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE)

proc draw(window: Window, img: RgbaImage, program, vao, tex: GLuint) =
  ## Aspect-fit letterbox: fullscreen quad + centered viewport.
  let ws = window.size
  let s = min(ws.x.float32 / img.width.float32,
    ws.y.float32 / img.height.float32)
  let vw = int32(img.width.float32 * s)
  let vh = int32(img.height.float32 * s)
  glViewport((ws.x - vw) div 2, (ws.y - vh) div 2, vw, vh)
  glClearColor(0.07f, 0.07f, 0.08f, 1.0f)
  glClear(GL_COLOR_BUFFER_BIT)
  glUseProgram(program)
  glBindVertexArray(vao)
  glActiveTexture(GL_TEXTURE0)
  glBindTexture(GL_TEXTURE_2D, tex)
  glDrawArrays(GL_TRIANGLES, 0, 6)
  swapBuffers(window)

proc main() =
  if paramCount() < 1:
    stderr.writeLine("usage: nview <image>")
    quit(1)
  let path = paramStr(1)
  if not fileExists(path):
    stderr.writeLine("nview: no such file: " & path)
    quit(1)
  var current: RgbaImage
  try:
    stdout.writeLine("nview: decoding " & path & " ...")
    stdout.flushFile()
    current = decodeBytes(readFile(path), path)
  except IOError as e:
    stderr.writeLine("nview: " & e.msg)
    quit(1)

  let iw = current.width.float
  let ih = current.height.float
  let f = min(1.0, min(MaxWinW / iw, MaxWinH / ih))
  let window = newWindow("nview — " & extractFilename(path),
    ivec2(int32(iw * f), int32(ih * f)))
  window.makeContextCurrent()
  loadExtensions()

  let program = linkProgram(
    compileShader(GL_VERTEX_SHADER, vertexSrc),
    compileShader(GL_FRAGMENT_SHADER, fragmentSrc))

  # Fullscreen quad; bottom vertices sample v=1 (last uploaded row =
  # image bottom) so top-down pixels land upright.
  var posData = [vec3(-1f, -1f, 0f), vec3(1f, -1f, 0f), vec3(1f, 1f, 0f),
    vec3(1f, 1f, 0f), vec3(-1f, 1f, 0f), vec3(-1f, -1f, 0f)]
  var uvData = [vec2(0f, 1f), vec2(1f, 1f), vec2(1f, 0f),
    vec2(1f, 0f), vec2(0f, 0f), vec2(0f, 1f)]

  var vao: GLuint
  glGenVertexArrays(1, addr vao)
  glBindVertexArray(vao)
  var posBuf: GLuint
  glGenBuffers(1, addr posBuf)
  glBindBuffer(GL_ARRAY_BUFFER, posBuf)
  glBufferData(GL_ARRAY_BUFFER, sizeof(posData), addr posData[0], GL_STATIC_DRAW)
  glVertexAttribPointer(0, 3, cGL_FLOAT, GL_FALSE, 0, nil)
  glEnableVertexAttribArray(0)
  var uvBuf: GLuint
  glGenBuffers(1, addr uvBuf)
  glBindBuffer(GL_ARRAY_BUFFER, uvBuf)
  glBufferData(GL_ARRAY_BUFFER, sizeof(uvData), addr uvData[0], GL_STATIC_DRAW)
  glVertexAttribPointer(1, 2, cGL_FLOAT, GL_FALSE, 0, nil)
  glEnableVertexAttribArray(1)

  var tex: GLuint
  glGenTextures(1, addr tex)
  upload(tex, current)

  let texLoc = glGetUniformLocation(program, "tex")
  glUseProgram(program)
  glUniform1i(texLoc, 0)

  window.onButtonPress = proc(b: Button) =
    if b == KeyEscape or b == KeyQ:
      window.closeRequested = true
  window.onFileDrop = proc(fileName, fileData: string) =
    var raw = fileData
    if raw.len == 0 and fileExists(fileName):
      raw = readFile(fileName)
    if raw.len == 0:
      return
    try:
      stdout.writeLine("nview: decoding " & fileName & " ...")
      stdout.flushFile()
      current = decodeBytes(raw, fileName)
      upload(tex, current)
      window.title = "nview — " & extractFilename(fileName)
    except IOError as e:
      stderr.writeLine("nview: " & e.msg)

  while not window.closeRequested:
    pollEvents()
    draw(window, current, program, vao, tex)

main()
