# LM-028 decode-only HEIC fixture

The three files are unmodified copies from
[`strukturag/libheif`](https://github.com/strukturag/libheif) at commit
`2bc82b493dd8896fab3226f01977c7ac9d2ea3b8`.

- Upstream license: LGPL-3.0-or-later (repository `COPYING`)
- `libheif-example.heic`: upstream `examples/example.heic`, 718,114 bytes,
  SHA-256 `7f8b363e4936c0666a25f64f3a92fda10bd8e5453be4592530b65a55dd98f3f2`,
  expected 1,280 × 854
- `libheif-ui-alpha.heic`: upstream `tests/data/with-alpha-512x512.heic`, 8,284
  bytes, SHA-256
  `dac399d3bf1019baaf5f88eef8b277087d0643e735db947c42355237bb9d0221`,
  expected 512 × 512
- `libheif-ui-rainbow.heic`: upstream `tests/data/rainbow-451x461.heic`, 7,080
  bytes, SHA-256
  `4b2ce727f093944975f143ba2b39c4c64511b766d94552f8d51a755916e7f983`,
  expected 451 × 461 clean-aperture image (452 × 462 coded dimensions)
- Use: decode-only performance and integrity fixture; never passed to an encoder

The LM-028 safe gate decodes this file only through FFmpeg's explicitly selected software
`hevc` decoder and rejects any appearance of `VTEncoderXPCService`. Apple ImageIO runtime
decode/encode is quarantined on this Mac because even a metadata-only `sips` probe spawned
that service on 2026-08-28.
