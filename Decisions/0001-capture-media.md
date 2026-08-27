# ADR 0001: Foreground-window capture media defaults

- Status: Accepted
- Date: 2026-08-27
- Story: LM-005
- Spike: S1

## Context

DeepShelves must persist pixels only from the uniquely resolved, policy-approved foreground window for the same revocable capture epoch. The S1 release-mode spike exercised a single long-lived `SCStream`, public-API focused-window resolution, filter updates, stale-buffer rejection, adaptive acceptance, HEVC encoding, duplicate-title and resize/minimize cases, excluded transitions, adversarial sentinel windows, and sleep/wake recovery.

The canonical raw measurements and environment declaration live under `Benchmarks/Results/S1/20260827T173516Z/`. The stable acceptance summary is `Results/LM-005/report.json`.

## Decision

Keep the planned foreground-window-only HEVC design and adopt these production constants:

| Setting | Value |
|---|---:|
| Focus polling | 100 ms |
| ScreenCaptureKit receive cadence | 2 fps |
| Active media acceptance | at most 1 fps plus immediate transition |
| Search indexing cadence | at most one frame every 2 seconds plus first epoch frame |
| Static heartbeat | 30 seconds |
| Idle suspension | 5 minutes |
| Maximum encoded long edge | 1,920 pixels, aspect-preserving even dimensions |
| Stream queue depth | 3 |
| Capture-to-media queue capacity | 4 |
| HEVC average bitrate | 2 Mbps |
| HEVC profile | Main, hardware encoder required |
| Keyframe and durable fragment interval | 1 second |
| Writer rollover | 29 seconds |
| Contractual maximum chunk duration | 30 seconds |
| Shareable-content refresh timeout | 2 seconds |
| Hung-refresh replacement cooldown | 30 seconds |

The writer rolls at 29 seconds because ScreenCaptureKit presentation timestamps arrive on a 500 ms cadence and AVFoundation may extend reported duration through the last sample interval. This one-second margin keeps every finalized or crash-recovered asset at or below the contractual 30-second duration without changing the receive or acceptance cadence.

`SCShareableContent` refreshes are bounded and lease-scoped. A request that does not return within two seconds produces a metadata-only `unresolvedWindow` gap. Duplicate refreshes are suppressed for 30 seconds, a replacement may then start, and a late completion from an older lease cannot mutate the newer lease. Capture never falls back to composited-display pixels.

## Consequences

- Every pixel-bearing chunk is fixed to one target window, capture epoch, and encoded dimension.
- Focus, policy, epoch, window identity, and dimensions are checked again immediately before append.
- Ambiguous, excluded, minimized, protected, missing, or refresh-timeout states persist no pixels.
- Hidden partial movies use one-second fragments, are synchronized before publication, and are atomically renamed only after successful completion.
- Lack of a hardware HEVC encoder is a visible capture failure; software HEVC is not silently selected.
- The allowed 1,680-pixel, 0.5 fps, and HEIC fallbacks were not used.

## Verification

`scripts/check-s1-capture-spike.sh` verifies the hour active workload, five-minute static workload, resource and storage bounds, focus correctness, typed exclusions, sentinel contamination, sleep/wake recovery, random decode latency, every referenced media file, and 30 forced-termination points. Unit and integration tests freeze the resolver, epoch admission, cadence, queue, rollover, refresh lease, chunk scope, capability, geometry, hardware-HEVC, and playable-media decisions.
