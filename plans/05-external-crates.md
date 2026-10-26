# 05 — External Crates to Clone into `references/`

User decision: clone each backing crate next to `references/image`, then port
from Rust source (no C bindings in final Nim code, except via `pkg/zlib`).

## Expected layout (clone if missing)

| Nim codec | Cargo spec | Clone into | Upstream |
|---|---|---|---|
| png | `png@0.18.0` | `references/png` | https://github.com/image-rs/image-png |
| jpeg (decode) | `zune-jpeg@0.5.15` | `references/zune-jpeg` (or `zune-image/zune-jpeg`) | https://github.com/zune-image/zune-image |
| jpeg (core) | `zune-core@0.5.0` | `references/zune-core` | same as above |
| jpeg (encode) | `jpeg-encoder@0.7.0` | `references/jpeg-encoder` | https://github.com/image-rs/jpeg-encoder |
| tiff | `tiff@0.11.2` | `references/tiff` | https://github.com/image-rs/image-tiff |
| exr | `exr@1.74.0` | `references/exrs` | https://github.com/johannesvollmer/exrs |
| avif | `ravif@0.13` | `references/ravif` | https://github.com/image-rs/ravif |
| avif types | `rgb@0.8.48` | (vendored via ravif, no separate clone needed) | https://github.com/kornelski/rgb |
| gif | `gif@0.14.1` | `references/gif` | https://github.com/image-rs/image-gif |
| webp | `image-webp@0.2.0` | `references/image-webp` | https://github.com/image-rs/image-webp |
| qoi | `qoi@0.4` | `references/qoi` (tiny, optional) | https://github.com/image-rs/image-qoi |

Check exact versions in `references/image/Cargo.toml:58-70` before cloning
(`cat references/image/Cargo.toml`).

## What to port from each (not wrap)

- `png`: `src/decoder/{mod,stream,cholors}.rs`, `src/filter.rs`, `src/adam7.rs`,
  `src/encoder.rs`, `src/chunk.rs`, `src/apng.rs`. Ignore its `deflate.rs` —
  use `pkg/zlib` instead.
- `zune-jpeg`: `src/decoder.rs`, `src/headers/*`, `src/huffman.rs`,
  `src/idct.rs`, `src/upsample.rs`, `src/color_convert.rs`.
- `jpeg-encoder`: `src/{encoder,tables,huffman,dct}.rs`.
- `tiff`: `src/decoder/{mod,ifd,tag,stream}.rs`, `src/decoder/*decompress*.rs`,
  `src/encoder/*`. LZW + Deflate paths map to `lzw.nim` / `zlib.nim`.
- `exrs`: `src/{header,image,compression/*,block,meta}.rs`, `src/math.rs`,
  half-float `src/io/*`.
- `ravif`: `src/{lib,av1encoder,u8utils}.rs` + `image/src/codecs/avif/yuv.rs:1277`,
  `ycgco.rs:410` (color math ports directly, AV1 bitstream stays Unsupported).
- `gif`: `src/{decoder,encoder,lzw,extensions}.rs`.
- `image-webp`: `src/{decoder,vp8,vp8l,mux,encoder}.rs`.

## Clone commands (run from `references/`)

```sh
git clone https://github.com/image-rs/image-png png
git clone https://github.com/image-rs/image-tiff tiff
git clone https://github.com/image-rs/image-gif gif
git clone https://github.com/image-rs/image-webp image-webp
git clone https://github.com/image-rs/jpeg-encoder jpeg-encoder
git clone https://github.com/zune-image/zune-image zune-image
git clone https://github.com/johannesvollmer/exrs exrs
git clone https://github.com/image-rs/ravif ravif
```

Then pin to Cargo versions:
`git -C references/png rev-parse HEAD` should match `png@0.18.0` tag;
same for others. If `zune-image` is a monorepo, the plan paths become
`references/zune-image/crates/zune-jpeg` and `.../zune-core`.

## License note

All above are MIT/Apache-2.0 like `image`. Keep attribution headers when
porting non-trivial functions (Huffman tables, Paeth, IDCT, YUV matrices).
