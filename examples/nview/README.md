# nview — photo gallery (macOS only)

`nview <image-or-directory>` decodes with the pure-Nim `image` library
and shows a native gallery: Cocoa window + toolbar
(`[‹ Prev] <picture name> [Next ›]`), Metal textured quad
(aspect-fit letterbox).

- A file argument opens its folder as the gallery (sibling images,
  sorted, starting at the file). A directory argument opens every
  supported image inside it.
- `←` / `→` (or the toolbar buttons) step through the gallery with
  wraparound; `Esc` / `Q` / `Cmd+Q` quits.

## Build

```sh
cd examples/nview
clue build --release
./bin/nview <image-or-directory>
```

Build `--release`: the pure-Nim JPEG decoder is minutes-per-photo in a
debug build on large files. Always use `--release` for actual viewing.

Requires Xcode CLT (Cocoa + Metal frameworks ship with macOS) and no
Nim-side UI deps: the UI is a small `src/nview_mac.m` (manual
refcounting, no ARC flag surgery) compiled into the binary via
`{.compile.}`. `src/nview.nim` owns the gallery model + decoders; the
two meet at a small C ABI (`galleryInit/Go/Current...`).

## Formats

Every LDR format the library guesses: PNG, JPEG, GIF (first frame only),
WebP, BMP, TIFF, TGA, PNM, ICO, QOI, HEIF. AVIF reports its
`Unsupported` stub message; 16-bit/float sources (HDR, EXR, farbfeld)
stay on the current picture with a clear error — no tone mapping in v1.
Large JPEGs decode scaled-down (denom 2/4 by dimension), matching what
the old viewer did for pixels the screen would downscale anyway.

## Memory

File bytes never enter the Nim heap: each slide mmaps the file
read-only (`memfiles`) and decodes straight from the view, which is
unmapped before the next slide (only HEIF copies once — that decoder's
seq API belongs to another agent). The decoded RGBA lives in one
grow-only display pool (`cached.pixels`): each slide blits into it via
`setLen` (capacity retained), and after GPU upload the length drops to
zero while the backing is kept — so a walk allocates the largest slide
once instead of once per photo, with no per-slide Rgba alloc. The Metal
texture is likewise grow-only, and the 64-byte quad goes through
`setVertexBytes`, so no per-frame buffer is created.

To check steady state without a debugger (which perturbs the target), two
environment hooks drive the real UI path and log the process footprint:

```sh
NVIEW_AUTO_MS=1000 NVIEW_LOG_MEM=1 ./bin/nview ~/Pictures
```

`NVIEW_AUTO_MS` advances on that interval, and `NVIEW_LOG_MEM` prints
`phys_footprint` after each slide. A wrapping gallery should climb only
while it discovers larger images or larger decode scratch, then stay flat.
