# LM-025 hardware media quarantine

LM-025 is technically blocked, not `blocked_human`. Two focused runs of the new hardware-required HEVC writer produced repeatable `dart-ave` AppleT8110DART kernel panics at 14:43 and 14:49 local time. The second run removed downscaling as the one changed variable, so downscaling is not required to trigger the failure. Both runs shared an `AVAssetWriterInputPixelBufferAdaptor` path whose accepted pool buffers had no explicit application-level retention through finalization.

## Minimal reproduction and raw evidence

The quarantined test is `CaptureMediaIntegrationTests.testHardwareRequiredVFRWriterDownscalesAndFinalizesScopedChunk`. It constructs `HEVCMediaWriter`, requires hardware HEVC, appends synthetic NV12 buffers, finalizes the MOV, and performs random decode. It must not be run on this host. Compact raw output and diagnostic hashes are recorded in `panic-analysis.json`; the system diagnostic files remain at their original absolute paths and are not copied into the repository.

## Safe diagnosis and attempted fixes

- Extracted `MediaWriterCore`, so scope, dimensions, VFR timing, backpressure commit semantics, locators, buffer lifetime, and finalization can be tested without AVFoundation or VideoToolbox.
- Extracted `MediaChunkPublisher`, so permissions, SHA-256, atomic rename, directory synchronization, and both publication fault boundaries can be tested using mock bytes.
- Refactored the production writer so every frame—same-size or downscaled—is copied into the adaptor's own `pixelBufferPool`, appended only through the adaptor, and retained by a strong ownership ledger until finish, failure, cancellation, or deinitialization completes.
- Added a pre-construction skip to all hardware media integration tests.
- Passed the six-scenario pure harness, deterministic software-fixture encoder, hashing/publication gates, real mock-process mid-write termination, source audit, whitespace/format checks, and compile-only package build. No VideoToolbox encoder or decoder runtime path was executed after quarantine.

## Fallback status and invariants

The S1 tuning steps for bitrate, 1680-pixel output, and 0.5 fps still initialize the same hardware HEVC path and are prohibited by the active safety constraint. The final documented fallback—independently encoded HEIC keyframes—changes the storage contract and explicitly requires an ADR. Foreground-window-only capture, local-only operation, epoch/policy identity, owner-only publication, and integrity invariants remain satisfiable. The fixed hardware-HEVC and runtime playability gates have not been demonstrated by this revision.

## Smallest decision required

Either explicitly reauthorize the quarantined hardware fixtures after an OS/firmware change or on an isolated expendable validation Mac, or authorize an architecture ADR evaluating the documented HEIC-keyframe fallback. Until then, keep LM-025 blocked and do not begin dependent LM-026.
