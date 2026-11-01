# docs — `image` package guides

In-depth documentation for the pure-Nim `image` package. The
[README](../README.md) stays the quickstart; this directory is the detail.

## Reading order

1. [architecture](architecture.md) — repo layout, module map, decode → encode flow
2. [core](core.md) — pixels, `ImageBuffer`, `DynamicImage`, views
3. [io](io.md) — format detection, `ImageReader` helpers, `Limits`
4. [errors](errors.md) — `ImageError` / `ImageResult[T]` contract
5. [codecs](codecs.md) — per-codec support, quirks, proc links
6. [converter](converter.md) — any-format → WebP API + math rules
7. [cli](cli.md) — `examples/webp_convert` (and `nview` pointer)
8. [testing](testing.md) — running tests, fixtures, oracles

## Conventions (for humans and LLMs)

- One concept per file; headers are stable anchors — link to them.
- Code snippets are minimal and use exact exported proc names; they are
  compile-checked against `src/image.nim` re-exports (`import image`).
- Behavior notes cite the source proc (`convert.nim:245`) instead of
  duplicating logic. If code and docs disagree, the code wins — fix the docs.
- All codecs return `ImageResult[T]`: check `.ok`, then use `.value`.
  Nothing in the decode/encode path raises on bad input.
