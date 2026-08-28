# LM-033 technical blocker

All safe thumbnail-pipeline work is implemented and verified with deterministic in-memory rasters, injected fake HEIC codec boundaries, atomic filesystem publication, integrity hashes, missing-file rebuild, and verified deletion.

The remaining acceptance gate is production validation against real HEIC source and thumbnail bytes: decode orientation/color metadata, encode the 480-pixel thumbnail, and decode the result to measure aspect/orientation/color fidelity. Apple ImageIO encode and decode are quarantined on this Mac because even a metadata-only `sips` probe spawned `VTEncoderXPCService`, while two earlier hardware-HEVC tests caused repeatable kernel panics. Executing that remaining gate here would violate the explicit safety constraint.

Resume probe: on an isolated validation host or after an approved codec boundary proves that it cannot initialize VideoToolbox, run the real-HEIC LM-033 fixture through the injected `ThumbnailHEICDecoding` and `ThumbnailHEICEncoding` adapters under the encoder-process tripwire. Require all aspect/orientation/color, hash, atomic-publication, deletion, and missing-file rebuild checks to pass before changing LM-033 from blocked to passed.
