# LM-033 blocker resolution

All safe thumbnail-pipeline work is implemented and verified with deterministic in-memory rasters, injected fake HEIC codec boundaries, atomic filesystem publication, integrity hashes, missing-file rebuild, and verified deletion.

The former production-codec gate is resolved by the owner-authorized ADR 0001 amendment. The shipping path uses a pinned, integrity-verified libheif 1.23.2 helper with only software x265 4.3 encoding and libde265 1.1.1 decoding. Its Mach-O closure has no ImageIO, AVFoundation, MediaToolbox, or VideoToolbox linkage.

Five real-codec Release tests plus the existing thumbnail tests passed under the encoder-process tripwire. They cover runtime inventory/hash tamper, genuine HEIC encode/decode, video-range capture conversion, 480-pixel orientation/aspect/sRGB thumbnail fidelity, malformed input, atomic publication, deletion, and missing-file rebuild. No Apple media runtime, hardware encoder test, or app launch occurred. LM-033 is passed.
