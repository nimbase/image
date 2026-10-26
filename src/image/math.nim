## Minimal math (Rect only) — imageops excluded per plan 06.
type
  Rect* = object
    x*, y*: uint32
    width*, height*: uint32

func initRect*(x, y, w, h: uint32): Rect =
  Rect(x: x, y: y, width: w, height: h)

func intersect*(a, b: Rect): tuple[hit: bool, r: Rect] =
  let x1 = max(a.x, b.x)
  let y1 = max(a.y, b.y)
  let x2 = min(a.x + a.width, b.x + b.width)
  let y2 = min(a.y + a.height, b.y + b.height)
  if x2 > x1 and y2 > y1:
    (true, Rect(x: x1, y: y1, width: x2 - x1, height: y2 - y1))
  else:
    (false, Rect())

func clampCoord*(v, lo, hi: uint32): uint32 =
  max(lo, min(v, hi))
