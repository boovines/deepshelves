# Baseline Spikes and Decision Gates

## Purpose

The architecture is fixed. These time-boxed spikes validate numeric defaults before the production packages depend on them. A spike may tune a constant or select the listed fallback only when the failure threshold is reproduced on the target Mac. It may not reopen native Swift, local-only operation, the privacy boundary, or canonical contract semantics.

Every run records git revision, Mac model, RAM, OS build, power mode, thermal state, release/debug configuration, input fixture hash, raw samples, and Instruments trace where applicable. Results live under `Benchmarks/Results/<spike>/<timestamp>/`; the conclusion is a short ADR in `Decisions/`.

## S1 — Capture, deduplication, and HEVC

### Prototype

Build a release-mode command app using one ScreenCaptureKit `SCStream` filtered with `SCContentFilter(desktopIndependentWindow:)` to the uniquely resolved focused `SCWindow`. Exercise `updateContentFilter` across focus changes, tag buffers with capture epochs, receive at 2 fps, downscale to a maximum 1920-pixel long edge, accept at most 1 fps, and write single-epoch, fixed-dimension, variable-frame-rate HEVC chunks of at most 30 seconds through `AVAssetWriter` with hardware acceleration requested.

Corpus: one hour replayed/operated workload containing static documents, scrolling, code editing, video playback, window switching, resize/minimize, duplicate-title windows, sleep/wake, and ten excluded transitions. Adversarial scenes place encoded sentinel grids in background password managers, private browsers, notifications, desktop/menu/Dock regions, split-screen neighbors, and the immediately previous focused window.

### Pass gates

- Mean app CPU below 6% and p95 below 12% on the declared target Mac during normal office use.
- Idle/static mean CPU below 1.5% after settling.
- Resident memory below 500 MB for capture-only spike.
- Active office storage below 75 MB/hour; static desktop below 10 MB/hour.
- Random frame decode p95 below 150 ms and p99 below 300 ms.
- At least 99% of eligible unambiguous focus changes begin the correct window epoch within one second; every unresolved/ambiguous case emits no pixels.
- Zero background, adjacent, excluded, notification, system-chrome, or stale-epoch sentinel pixels reach partial/final media or any derivative.
- Every media chunk contains exactly one target window ID, one capture epoch, and one encoded dimension.
- Chunks remain playable after forced termination at every second of a write.

### Allowed tuning sequence

1. Tune visual-difference threshold and HEVC bitrate/quality.
2. Reduce maximum long edge to 1680 if storage/CPU fails and OCR fixtures lose less than two percentage points recall.
3. Reduce active acceptance to 0.5 fps only if transition frames remain immediate and retrieval Recall@10 loses less than two points.
4. Use independently encoded HEIC keyframes instead of HEVC only if random decode or crash integrity cannot pass; this requires an ADR because storage layout changes.

There is no tuning step that permits composited-display capture. Window-resolution uncertainty always fails to a metadata-only gap.

## S2 — Accessibility, OCR, browser context, and privacy

### Prototype

Capture bounded Accessibility trees from Safari, Chrome, Arc/Dia-family Chromium, Edge, Firefox, Finder, Notes, Mail, Calendar, Preview/PDF, Terminal, VS Code, Xcode, Slack, and one Electron app. Run Apple Vision recognition on the paired 200-frame OCR fixture. Implement address-field URL adapters without inspecting page DOM or network traffic.

### Pass gates

- AX provides useful visible text or title context on at least 80% of the 250 AX fixtures.
- AX traversal finishes below 50 ms p95 and never blocks capture.
- Vision OCR word recall at intersection-over-union ≥0.5 is at least 0.90 for high-contrast Latin UI and 0.82 over the full fixture.
- AX/OCR merge reduces duplicate normalized tokens below 3% without removing more than 1% of unique ground-truth text.
- Supported-browser host detection accuracy at least 0.98 outside private mode.
- All exclusion/private-context and background-sentinel fixtures persist zero prohibited media, thumbnail, text, title, URL, vector, cache, or log content.
- When URL inspection fails and a site rule exists, browser capture is suppressed within one frame.

Fallback: if an app’s AX traversal exceeds the budget or is unstable, store only app/window metadata and use OCR. If a browser adapter cannot meet privacy accuracy, mark it unsupported and conservatively suppress browser capture whenever site exclusions exist.

## S3 — MobileCLIP-S0 packaging and embeddings

### Prototype

Convert and bundle both MobileCLIP-S0 encoders as compiled Core ML resources with fixed preprocessing/tokenization. Validate model output against reference vectors, then embed the 500-frame visual corpus and 100 query texts using the Neural Engine where available.

### Pass gates

- No runtime download and no network access during first launch or inference.
- Model and tokenizer files pass startup SHA-256 verification.
- Cosine similarity with reference implementation is at least 0.999 for fixed inputs.
- Image embedding p95 below 100 ms and text embedding p95 below 50 ms, single-job concurrency, without sustained capture degradation.
- Visual-only Recall@10 at least 0.75 on the labeled subset before ranking improvements.
- Bundled model footprint below 250 MB and enrichment resident memory below 750 MB.

Fallback: test MobileCLIP-S1 only if S0 misses Recall@10 by more than five points and still passes energy/memory limits. Do not add remote inference or an unversioned model.

## S4 — Exact vector scan at archive scale

### Prototype

Write normalized Float16 vectors in one model-versioned contiguous file, memory-map read-only, filter candidate offsets from SQLite, convert chunks to Float32, and score dot products with Accelerate. Test deterministic 100k, 500k, and 1M frame archives with unfiltered and app/site/day filtered queries.

### Pass gates at one million frames

- Unfiltered exact scan p95 below 750 ms and p99 below 1,000 ms.
- Common day/app-filtered scan p95 below 250 ms.
- Incremental memory attributable to vector search below 500 MB.
- Scores and stable ordering match a scalar Float32 reference within `1e-3`.
- A truncated vector file is detected before results and can be rebuilt from model jobs.

Fallback: add a versioned USearch HNSW sidecar only if either latency or memory fails. Preserve exact scan for filtered small candidate sets and evaluation truth. Do not place large vector blobs in SQLite.

## S5 — SQLCipher, transactions, and helper access

### Prototype

Exercise GRDB/SQLCipher with WAL under concurrent capture inserts, enrichment updates, searches, retention deletion, and MCP read projections. Store a random 256-bit key in a Keychain access group shared by the signed app/CLI/MCP helpers. Force termination around media rename/database commit and chunk replacement.

### Pass gates

- Fresh database bytes, WAL, and temporary files reveal none of 100 seeded sentinel strings.
- Key is inaccessible to an unsigned helper and after access-group mismatch.
- Encryption adds less than 20% p95 latency to the representative query/write suite.
- Ten thousand forced crash points recover to a consistent state with no searchable missing media and no orphan ready media.
- Deleting a sentinel and checkpointing/vacuuming leaves it absent from database files, WAL, vector file, thumbnail tree, media decode, logs, and helper output.

If the shared Keychain design fails signing/access tests, embed CLI/MCP modes in the signed application executable and use `--cli`/`--mcp` entry points rather than weakening Keychain ACLs.

## S6 — Native grid, timeline, and media decode

### Prototype

Build the specified global panel and detail view against deterministic stores containing 10,000 cards, 24 hours of timeline markers, gaps, thumbnails, and HEVC chunks. Use lazy SwiftUI containers and an actor-owned decode cache. Measure with release build and XCUITest scroll/scrub scripts.

### Pass gates

- Search panel visible and focused within 150 ms warm and 400 ms cold after shortcut.
- Initial 60-card result render p95 below 200 ms after results are available.
- Grid fast-scroll sustains at least 55 fps p95 with memory below 750 MB.
- Timeline scrub thumbnail feedback below 50 ms p95 and full-frame settle below 200 ms p95.
- No stale screenshot appears after rapid selection changes.
- Window resize, light/dark switch, VoiceOver navigation, and 40%-expanded pseudo-localized strings produce no clipped critical controls.

Fallback: replace only the measured hot collection with an `NSCollectionView` wrapper while retaining SwiftUI composition and `MemoryDesignSystem` tokens. Do not switch the application to a web UI.

## S7 — Offline and dependency closure

### Prototype

Run first launch, onboarding, capture, search, visual inference, deletion, export, CLI, and MCP under a deny-all outbound network policy. Inspect linked frameworks, packages, update checks, logging, model resources, and DNS/socket activity.

### Pass gates

- Zero outbound DNS, TCP, UDP, HTTP, or QUIC attempts in shipping targets.
- The app reaches full visual-search functionality on a fresh offline Mac after installation.
- Every binary/resource has a recorded source, version, license, hash, and update procedure.
- No telemetry, crash upload, remote favicon, remote font, remote model, or automatic update component is linked.
- Build tools may access pinned dependencies only during a documented build/bootstrap step; release artifacts are reproducible from the dependency cache.

## Spike completion rule

LM-005 through LM-008 are complete only when raw results and ADRs exist and the chosen constants are copied into production configuration tests. A failed gate does not permit a vague “optimize later”; apply the listed tuning sequence, record the outcome, and escalate only if every listed fallback fails.
