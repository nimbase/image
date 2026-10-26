## Minimal metadata (Cicp subset) — moxcms excluded.
type
  CicpPrimaries* = enum
    cpUnknown = 0
    cpSRGB = 1
    cpBT2020 = 9
    cpDisplayP3 = 12

  CicpTransfer* = enum
    ctSRGB = 1
    ctLinear = 8
    ctPQ = 16
    ctHLG = 18
    ctUnknown = 0

  Cicp* = object
    primaries*: uint8
    transfer*: uint8
    matrix*: uint8
    fullRange*: bool

  Orientation* = enum
    orNormal = 1
    orMirrorH = 2
    orRotate180 = 3
    orMirrorV = 4
    orMirrorHRotate270 = 5
    orRotate90 = 6
    orMirrorHRotate90 = 7
    orRotate270 = 8

func defaultCicp*(): Cicp =
  Cicp(primaries: 1, transfer: 1, matrix: 0, fullRange: true)
