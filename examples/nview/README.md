# nview — minimal photo viewer

`nview photo.png` decodes with the pure-Nim `image` library and shows the
result in a `windy` window (OpenGL 4.1 textured quad, aspect-fit
letterbox).

## Build

```sh
cd examples/nview
clue build --release
./bin/nview <image>
```

Build `--release`: the pure-Nim JPEG decoder is minutes-per-photo in a
debug build on large files (a 24 MP progressive JPEG takes ~19 s even
in release). Always use `--release` for actual viewing.

Requires a C toolchain plus the system OpenGL headers (ship with macOS
Xcode CLT; on Linux install your distro's GL dev package). Nim-side deps
(`windy`, `opengl`, `archive`, `image`) resolve through `clue`.

## Use

```sh
nview photo.png   # open a file
```

- Drag a file onto the window to switch images.
- `Esc` / `Q` quits. Window starts at image size clamped to 1280x800.

## Formats

Every LDR format the library guesses: PNG, JPEG, GIF (first frame only),
WebP, BMP, TIFF, TGA, PNM, ICO, QOI, HEIF. AVIF reports its
`Unsupported` stub message; 16-bit/float sources (HDR, EXR, farbfeld)
exit with a clear error — no tone mapping in v1.
