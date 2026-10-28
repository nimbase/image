# Package

version       = "0.1.0"
author        = "Nimbase Community"
description   = "nview - minimal photo viewer (windy + OpenGL) for the pure-Nim image library"
license       = "MIT OR Apache-2.0"
srcDir        = "src"
bin           = @["nview"]


# Dependencies

requires "nim >= 2.2.0"
requires "windy >= 0.5.0"
requires "opengl >= 1.2.6"
requires "archive >= 0.1.0"
requires "image >= 0.1.0"