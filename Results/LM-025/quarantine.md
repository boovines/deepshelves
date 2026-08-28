# LM-025 hardware video-encoder quarantine

The architecture blocker is resolved by the authorized HEIC-keyframe fallback, but the hardware video-encoder quarantine is permanent on this Mac. Two focused HEVC/VideoToolbox runs produced repeatable `dart-ave` AppleT8110DART kernel panics at 14:43 and 14:49 local time on 2026-08-28. The second run removed downscaling as the changed variable, so downscaling was not required to trigger the failure.

## Preserved incident evidence

The former quarantined test constructed the production HEVC writer, initialized hardware encoding, wrote synthetic NV12 buffers, finalized a MOV, and attempted random decode. Its compact output, diagnostic hashes, and original system-diagnostic paths remain in `panic-analysis.json`. The reports are historical evidence only and must not be reproduced on this host.

## Permanent local prohibition

Do not run any test, probe, benchmark, app path, or one-variable experiment on this Mac that can construct the former HEVC writer, initialize AVAssetWriter video encoding, reach a VideoToolbox hardware encoder, or attempt to reproduce either panic. The prohibition includes the first three former S1 tuning variants because each reaches the same hardware encoding surface.

## Authorized resolution

ADR 0001 now selects independently encoded HEIC keyframes in immutable logical chunk directories. The shipping capture target contains no AVAssetWriter, VideoToolbox, HEVC codec, or former HEVC writer reference. Production ImageIO HEIC encoding is compiled but was not executed by LM-025 tests; all runtime verification used deterministic fakes at the narrow encoding boundary.

Safe verification proves foreground-window identity scoping, local-only operation, canonical manifest and per-frame integrity, exact search evidence paths, owner-only permissions, atomic no-replace publication, mid-write recovery, retained-only republishing, retention removal, and deleted-sentinel absence. The architecture decision therefore passes LM-025 without waiving or weakening a privacy, integrity, deletion, or foreground-window invariant.

Future video-codec reconsideration requires a separate ADR and an isolated expendable validation host after an OS or firmware change. It is not a pending LM-025 gate.
