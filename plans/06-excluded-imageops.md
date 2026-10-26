# 06 — EXCLUDED: Processing Functions (out of scope for now)

Per user decision, no `imageops` port in this phase.

## Explicitly excluded

From `references/image/src/imageops/` (all of it):
- `affine.rs:388` (rotate/flip/translate)
- `colorops.rs:714` (grayscale, invert, contrast, brighten, huerotate)
- `resize.rs` + `sample.rs:1946` + `filter_1d.rs:953` (nearest/triangle/catmullrom/
  gaussian/lanczos3 sampling)
- `fast_blur.rs:593`
- `mod.rs:573` (dispatch + `FilterType`)

Also excluded:
- `images/buffer_par.rs:335` (rayon parallel paths — no Nim threads yet)
- `metadata/moxcms.rs:517` (color-management via moxcms; keep `cicp.rs` only)
- `hooks.rs:262` (progress hooks tied to imageops/resize)

## What stays (minimal, codec-required only)

- `math/rect.rs` -> `math.nim`: `Rect(x,y,width,height)` + intersect/clamp.
  Needed by `buffer.cropInPlace`, PNG APNG offsets, TIFF strips/tiles.
- `math/utils.rs`: `clamp`, `lerp` helpers needed by color conversions.
- `metadata/cicp.rs:1391` -> `metadata.nim`: `Cicp`, primaries/transfer enums.
  Needed by buffer color-space fields + AVIF YUV path.
- `animation.rs:477` -> `animation.nim`: `Delay, Frame, Frames`, `LoopCount`.
  Needed by GIF/APNG/WebP sequences — this is container framing, not
  "processing", so it stays.
- `images/flat.rs:2118` -> `flat.nim`: stays (FFI-adjacent buffer layout,
  needed for `save_buffer` parity).

Revisit imageops as a separate follow-up project after codecs are green.
