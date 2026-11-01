# CLI examples

## webp_convert — any image to WebP

`examples/webp_convert` (own nimble package, `image` as develop dep):

```sh
cd examples/webp_convert
clue build --release
./bin/webp_convert photo.jpg photo.webp --quality 75
```

```sh
webp_convert photo.png photo.webp              # lossy q75 (default)
webp_convert photo.jpg photo.webp -q 90        # lossy q90
webp_convert photo.tiff photo.webp --lossless  # VP8L lossless
```

- Always build `--release`: the pure-Nim encoders are slow in debug
  (a 24 MP JPEG decodes in ~19 s even in release, plus VP8L on top).
- Prints `input (WxH) -> output (bytes, mode, time)`.
- Exit non-zero with a stderr message for unreadable input, unknown
  format, out-of-range quality (`--quality 1..100`, `-q` alias), or write
  failures. `--help` / `-h` prints usage.
- Inputs: PNG, JPEG, GIF (first frame), WebP, BMP, TIFF, TGA, PNM, ICO,
  QOI, HDR, OpenEXR, Farbfeld, AVIF (stub error), HEIF/HEIC. 16-bit/float
  auto-downconvert; see [converter](converter.md) for the math.

## nview — minimal photo viewer

`examples/nview` (`windy` + OpenGL): `nview` opens an image with the
pure-Nim decoders. Viewer only, not part of the library API.

## Adding a new example

Mirror `webp_convert`: own `<name>.nimble` with
`requires "image >= 0.1.0"`, `srcDir = "src"`, `bin = @["<name>"]`, and a
`.gitignore` containing `bin/`.
