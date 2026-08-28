# ADR 0001: Foreground-window capture media defaults

- Status: Accepted representation; runtime codec blocked by LM-028 safety quarantine
- Original date: 2026-08-27
- Amendment date: 2026-08-28
- Stories: LM-005, LM-025, LM-028
- Spike: S1

## Context

DeepShelves must persist pixels only from the uniquely resolved, policy-approved foreground window for the same revocable capture epoch. The S1 release-mode spike exercised a single long-lived `SCStream`, public-API focused-window resolution, filter updates, stale-buffer rejection, adaptive acceptance, HEVC encoding, duplicate-title and resize/minimize cases, excluded transitions, adversarial sentinel windows, and sleep/wake recovery.

The canonical S1 measurements and environment declaration live under `Benchmarks/Results/S1/20260827T173516Z/`; `Results/LM-005/report.json` is the stable acceptance summary. S1 originally selected variable-frame-rate hardware HEVC in QuickTime chunks.

During LM-025, two focused runs that initialized the hardware HEVC/VideoToolbox encoder caused repeatable `dart-ave AppleT8110DART` kernel panics at 14:43 and 14:49 local time on 2026-08-28. The panic reports, exact commands, and safe static diagnosis are retained in `Results/LM-025/`. No further hardware encoder validation is permitted on this Mac.

The documented S1 fallback sequence allows independently encoded HEIC keyframes when random decode or crash integrity cannot be safely established, but requires an ADR because the storage layout and media locator contract change. The owner authorized that fallback on 2026-08-28.

During LM-028, a metadata-only `sips` probe of a pinned HEIC fixture unexpectedly started
`VTEncoderXPCService`. The LM-028 tripwire detected the service and it was terminated
immediately; no Xcode process was active and no further Apple ImageIO runtime probe was
attempted. This does not invalidate the independent-keyframe representation, manifest, or
publication design, but it means Apple ImageIO encode and decode are both runtime-
quarantined on this Mac until a codec boundary can prove that the service is never
initialized.

## Decision

Retain the proven foreground-window resolver, revocable epoch, privacy preflight, adaptive acceptance, downscale, and rollover decisions. Replace the canonical hardware-HEVC writer with independently encoded HEIC keyframes grouped into immutable logical chunk directories.

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
| Canonical media codec | independently encoded HEIC still image per accepted frame |
| HEIC quality | 0.82 unless a later measured ADR changes it |
| Runtime codec on this Mac | fail closed; Apple ImageIO encode/decode quarantined |
| Logical writer rollover | 29 seconds |
| Contractual maximum chunk duration | 30 seconds |
| Shareable-content refresh timeout | 2 seconds |
| Hung-refresh replacement cooldown | 30 seconds |

Each logical chunk is one directory:

```text
media/YYYY/MM/DD/<chunk-uuid>/
  manifest.json
  frames/<frame-uuid>.heic
```

The canonical manifest binds the chunk ID, capture epoch ID, target window ID, fixed dimensions, ordered logical presentation times, exact frame IDs and relative asset paths, byte counts, and per-frame SHA-256 digests. The `MediaChunk.sha256` is the SHA-256 of the canonical manifest bytes; `byteCount` covers the manifest and all referenced frame assets. A searchable frame carries the exact HEIC asset path in addition to its chunk ID and logical presentation time.

The writer stages the complete directory as a hidden sibling, writes every frame through a sibling partial file with mode `0600`, synchronizes it, and atomically renames it inside staging. Finalization writes and synchronizes the canonical manifest last, validates every referenced asset and digest, synchronizes the staging tree, atomically renames the staging directory without replacement, synchronizes the parent directory, and only then permits the database transaction to make the chunk searchable. A crash before directory publication exposes no ready chunk; a crash after rename but before the database commit leaves an unreferenced ready directory for deterministic startup reconciliation.

`SCShareableContent` refreshes remain bounded and lease-scoped. A request that does not return within two seconds produces a metadata-only `unresolvedWindow` gap. Duplicate refreshes are suppressed for 30 seconds, a replacement may then start, and a late completion from an older lease cannot mutate the newer lease. Capture never falls back to composited-display pixels.

## Invariant analysis

| Invariant | HEIC-keyframe preservation |
|---|---|
| Foreground-window isolation | The existing prefilter, epoch, target, policy, focus, and dimension checks run immediately before each independent encode; the encoder receives only an admitted foreground-window pixel buffer. |
| Local-only storage | Encoding and publication are in-process filesystem operations beneath the owner-only archive. No network API or upload path is introduced. |
| Privacy identity | Every manifest and frame locator is bound to one chunk ID, capture epoch, target window, fixed dimensions, and frame ID; mismatched identity fails closed before bytes are accepted. |
| Atomic publication | The fully validated hidden directory is published by one no-replace rename followed by parent-directory synchronization, before the database visibility transaction. |
| Integrity | Canonical manifest hashing plus per-frame byte count and SHA-256 detects missing, substituted, reordered, duplicated, or corrupt assets. |
| Search evidence | Results cite the exact independently decodable source HEIC for the matched frame; logical presentation time remains timeline ordering evidence rather than a video seek approximation. |
| Retention | Complete logical chunks remain bounded to 30 seconds and can be removed as owner-only directories using the existing tombstone and reconciliation protocol. |
| Forensic deletion | Partial deletion constructs and verifies a replacement directory containing only retained frame IDs, atomically swaps database references, then disposes the old directory; the manifest is a complete inventory for absence proofs. |

## Consequences

- Every pixel-bearing chunk remains fixed to one target window, capture epoch, and encoded dimension.
- Focus, policy, epoch, window identity, and dimensions are checked again immediately before encode.
- Ambiguous, excluded, minimized, protected, missing, or refresh-timeout states persist no pixels.
- Exact-frame random access requires no GOP seek, but the runtime decoder must still pass
  the no-VideoToolbox tripwire before it can ship on this Mac.
- Crash recovery reasons about complete directories and canonical manifests instead of playable partial movies.
- Moment/range deletion copies only retained independent frames into a replacement chunk; it never re-encodes adjacent retained evidence.
- Storage overhead is expected to exceed inter-frame HEVC for changing content. The existing 30-day/20-GB retention and hard-budget controls remain mandatory, and LM-028 plus LM-082 must measure the revised corpus before release.
- The app must not claim application-level media encryption. HEIC assets retain the FileVault plus owner-only-permission boundary.
- The former `HEVCMediaWriter`, AVAssetWriter, and VideoToolbox encoder path is removed from the shipping capture target. The two panic artifacts remain historical evidence and must never be reproduced on this Mac.
- `HEICKeyframeWriter` has no implicit production encoder. Every caller must inject an
  encoder explicitly, and legacy capture/decode harnesses default to a fail-closed
  quarantine boundary. This prevents an app or test launch from silently reaching Apple
  ImageIO while LM-028 is blocked.
- The V1 HEVC JSON reader remains for previously generated synthetic/spike evidence. New canonical archives use contract version 2 with `heicKeyframes` / `heicKeyframeDirectory` and exact frame asset paths.

## Alternatives considered

- **Retry hardware HEVC on this Mac:** rejected because two reproducible kernel panics make another validation run unsafe.
- **Software HEVC video:** rejected because it preserves the risky container/seek/finalization surface and violates the no-silent-high-CPU fallback rule.
- **PNG keyframes:** operationally simple and lossless, but materially larger for the rolling archive; reserved as a last-resort diagnostic format.
- **Single multi-image HEIC container:** rejected because independently addressable files give simpler atomic recovery, exact evidence identity, corruption isolation, and deletion proofs.

## Verification

LM-025 verification is restricted to source inspection, compile-only builds, deterministic boundary fakes, canonical-manifest fixtures, and filesystem fault injection that cannot initialize AVAssetWriter, VideoToolbox, or a hardware HEVC encoder. The gate proves scope rejection, fixed-dimension/downscale planning, ≤30-second ordering, exact-frame lookup, per-frame and manifest integrity, owner-only permissions, before/after-rename recovery, retained-only replacement, full retention removal, and forensic sentinel absence. Production ImageIO HEIC encoding is compiled but is not executed on this Mac as part of the gate.

LM-028 safely exercises 62 focused Release unit tests plus five fake-media integration
tests, an eight-hour synthetic office workload, and a 72-hour accelerated workload. A
pinned three-file libheif corpus decoded through FFmpeg's explicitly selected software
HEVC decoder (`-hwaccel none`, one thread) measures a worst p95 of 85.664 ms and 32.5 MB
peak child RSS. The weighted 1920×1080 corpus is 197,487 bytes per accepted frame; the
office model projects 18.414 GB over 30 eight-hour days, with a queue peak of four and zero
persisted prohibited sentinel. These results validate the layout and safe software decode
boundary, but they do not satisfy the real eight-hour production capture/resource gate.
LM-028 remains technically blocked on that exact gate. LM-082 repeats the long-soak,
offline privacy, integrity, retention, and deletion gates against HEIC source assets.

## Revisit triggers

Revisit the codec only after a macOS/firmware change or on an isolated expendable validation host, and only through a new ADR with reproducible crash-integrity, deletion, decode, privacy, resource, and migration evidence. Archive identity and exact-frame locators must remain stable across any future representation migration.
