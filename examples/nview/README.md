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
