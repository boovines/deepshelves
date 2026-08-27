# Local Screen Memory — Master Build Plan

## Goal

Build a personal, local-only macOS application that is functionally faithful to the currently described Coast Local preview:

- Quiet, always-available visual memory
- On-device Accessibility extraction, OCR, and visual retrieval
- Search by content, application, website, and time
- Screenshot results and an exact-time visual timeline
- Activity heatmaps and application totals
- Pause, exclusions, retention, deletion, and export
- Scoped local CLI and MCP access for trusted agents
- Optional on-device audio transcription after the visual product is stable
- No accounts, cloud storage, telemetry, remote AI, or required network access

This is an independent implementation of public product behavior. It must not copy Coast code, assets, wording, or proprietary visual design.

## Architecture decision

The implementation is a clean-room, native macOS application written in Swift. There is no remaining Screenpipe-versus-greenfield decision and no Tauri/webview layer.

### Fixed stack

| Area | Decision |
|---|---|
| Platform | Apple Silicon, macOS 15 or later |
| Language | Swift 6 with strict concurrency |
| Product UI | SwiftUI with focused AppKit interop |
| UI standardization | Native SwiftUI controls, SF Symbols, semantic design tokens, Apple HIG |
| Capture | ScreenCaptureKit SCStream filtered to exactly one approved foreground SCWindow |
| Activity signals | NSWorkspace, Accessibility AX APIs, coarse CGEventTap event classes |
| Media | Adaptive foreground-window keyframes encoded into ≤30-second, single-epoch HEVC QuickTime chunks |
| Database | GRDB over SQLite WAL with FTS5 |
| Text extraction | Accessibility first, Apple Vision OCR fallback |
| Visual retrieval | Bundled Core ML MobileCLIP-S0 image/text encoders |
| Vector index | Versioned Float16 flat index with exact Accelerate scan for V1 |
| Ranking | FTS5 BM25 plus visual similarity fused with reciprocal-rank fusion |
| Audio | WhisperKit, off by default and implemented late |
| Agent integration | Official Swift MCP SDK over standard input/output |
| Secrets | macOS Keychain |
| Process security | Hardened Runtime on; App Sandbox off because global Accessibility/event monitoring is core behavior |
| Launch at login | SMAppService |
| Build generation | Pinned XcodeGen specification plus xcodebuild |
| Tests | Swift Testing, XCTest/XCUITest, deterministic screenshot harness, benchmark executables |
| Network | No runtime networking code in the shipping target |

### Why this is the chosen architecture

- Coast advertises inference on Apple’s Neural Engine, for which Core ML is the supported application path.
- Coast’s disclosed local database and OCR/Accessibility behavior map directly to Apple frameworks and SQLite.
- Coast’s terms disclose FFmpeg, SQLCipher, and Sparkle components, suggesting a native local-media architecture rather than a required cloud backend.
- A native app avoids a webview, JavaScript runtime, and cross-language bridge in an always-running process.
- SwiftUI provides standardized macOS controls and behavior without importing a mobile-oriented design system.
- Clean-room ownership avoids Screenpipe’s personal/non-commercial license becoming a future architectural trap.

Screenpipe remains a useful public behavioral and performance reference, but no Screenpipe source is copied.

## High-level work buckets

| Bucket | Plan | Primary output |
|---|---|---|
| Product definition | [01-product-fidelity.md](01-product-fidelity.md) | Fidelity matrix, journeys, non-goals, success measures |
| Platform and capture | [02-platform-capture.md](02-platform-capture.md) | Native runtime, permissions, adaptive capture, HEVC chunks |
| Local enrichment | [03-enrichment-pipeline.md](03-enrichment-pipeline.md) | Accessibility, OCR, MobileCLIP, optional transcription |
| Storage and lifecycle | [04-storage-lifecycle.md](04-storage-lifecycle.md) | GRDB schema, media layout, migrations, retention, deletion |
| Retrieval | [05-retrieval-search.md](05-retrieval-search.md) | FTS5, visual vectors, query parser, fusion, evaluation |
| Interface | [06-product-ui-design-system.md](06-product-ui-design-system.md) | SwiftUI design system, search, timeline, activity, settings |
| Agent access | [07-agent-local-api.md](07-agent-local-api.md) | Shared query library, CLI, MCP, access policy |
| Privacy and security | [08-privacy-security.md](08-privacy-security.md) | Offline boundary, exclusions, access control, deletion proof |
| Reliability and evaluation | [09-performance-reliability-evaluation.md](09-performance-reliability-evaluation.md) | Test layers, budgets, soak tests, release gates |
| Contracts and fixtures | [10-contracts-and-fixtures.md](10-contracts-and-fixtures.md) | Shared types, database contracts, deterministic fixture corpus |
| Concrete UX | [11-ux-specification.md](11-ux-specification.md) | Window geometry, tokens, wireframes, keyboard behavior |
| Baseline spikes | [12-baseline-spikes.md](12-baseline-spikes.md) | Measurements that validate fixed implementation defaults |
| Executable backlog | [13-implementation-backlog.md](13-implementation-backlog.md) | Issue-sized dependency-ordered stories |
| Goal-thread runbook | [14-goal-thread-runbook.md](14-goal-thread-runbook.md) | Resumable execution, checkpoints, and human-only gates |

## System architecture

    AX focus + SCShareableContent window resolution
                    |
             CaptureCoordinator actor
                    |
       PrivacyPolicy-approved capture epoch
                    |
        SCContentFilter: one SCWindow only
                    |
        epoch/focus/policy recheck
                    |
          MediaWriter + DatabaseWriter
          ≤30-second HEVC chunks + SQLite
                    |
            EnrichmentScheduler actor
       AX text / Vision OCR / MobileCLIP
                    |
              SearchEngine actor
       FTS5 + exact vector scan + fusion
             /                    \
       SwiftUI product          SharedQueryKit
    search/timeline/settings     CLI + MCP helper

Capture and canonical persistence never depend on semantic models, agent availability, the main product window, or network access. Unapproved background, desktop, notification, menu-bar, Dock, and adjacent-window pixels never enter the capture stream.

## Repository shape

The fixed implementation root is `/Users/justinhou/Development/deepshelves`. LM-001 creates and initializes it as the local Git repository, creates a private GitHub repository named `deepshelves` with `origin` pointing to it, then copies this planning set into `Docs/Plan/` as the committed execution snapshot. From that point the in-repository snapshot is canonical for the build; later planning changes must be deliberately synchronized through a documentation commit. If GitHub authentication is unavailable, use human gate H8; never create a public repository as a fallback.

    LocalMemory/
      project.yml
      LocalMemory.xcworkspace
      Apps/
        LocalMemoryApp/
        LocalMemoryCLI/
        LocalMemoryMCP/
      Packages/
        MemoryContracts/
        MemoryCapture/
        MemoryStore/
        MemoryEnrichment/
        MemorySearch/
        MemoryAgentAccess/
        MemoryDesignSystem/
        MemoryTestSupport/
      Resources/
        Models/
        Assets/
      Tests/
        Unit/
        Integration/
        UI/
        Privacy/
        Performance/
      Fixtures/
      Benchmarks/
      Decisions/
      Docs/Plan/
      progress.md
      phase-state.json

The Xcode application targets are thin composition roots. Domain logic belongs in local Swift packages so it can be tested without launching the UI.

## Fixed implementation defaults

### Capture and media

- One long-lived SCStream filtered with `SCContentFilter(desktopIndependentWindow:)` to the uniquely resolved, approved foreground window on the main display.
- Never capture the composited display in V1.
- On focus/window/URL change, revoke the old epoch, flush candidates, update the filter, then accept only buffers delivered under the new verified epoch.
- If the target is missing, ambiguous, minimized, protected, or on an unsupported display, write a typed metadata-only gap and no pixels.
- Receive frames at up to 2 fps while active.
- Maximum persisted long edge of 1920 pixels.
- Accept at most 1 visual keyframe per second during meaningful change.
- Immediately accept foreground application, window, and URL transitions.
- Reduce to one heartbeat every 30 seconds when static.
- Stop accepting after five minutes idle while keeping recovery cheap.
- Recheck privacy rules immediately before writing.
- Encode accepted frames into variable-frame-rate HEVC chunks lasting at most 30 seconds; end a chunk on target-window, capture-epoch, or encoded-dimension change.
- Generate 480-pixel thumbnails only for searchable frames.
- Index at most one frame every two seconds plus immediate context transitions.

[12-baseline-spikes.md](12-baseline-spikes.md) may override a default only after its stated failure threshold is measured.

### Storage and retention

- Root: ~/Library/Application Support/LocalMemory/
- GRDB/SQLite WAL, with media outside SQLite.
- SQLCipher required before personal dogfood; random key in Keychain.
- Media and thumbnails rely on FileVault and strict filesystem permissions in V1.
- Default retention: 30 days.
- Default hard cap: 20 GB.
- Remove oldest complete chunks first when the cap is reached.
- Delete-one-moment rewrites its containing ≤30-second single-window chunk.
- Time-range deletion removes or rewrites every overlapping chunk.
- Every derived artifact cascades from canonical deletion.

The UI must say that database text is app-encrypted while visual media is protected by macOS/FileVault. It must not claim blanket archive encryption.

### Retrieval

1. Deterministic app/site/time parsing.
2. FTS5 BM25 over Accessibility, OCR, titles, URLs, and optional transcripts.
3. MobileCLIP-S0 text-to-image similarity.

Vectors are model-versioned Float16 values in a contiguous rebuildable file, with capture-ID/offset metadata in SQLite. Search uses memory-mapped, chunked exact cosine scanning with Accelerate.

Do not add HNSW, sqlite-vec, a local LLM, or text-semantic embeddings unless a baseline threshold fails. Exact scan is easier to verify, supports arbitrary filters, and is sufficient for the initial single-user archive.

FTS and visual ranks use reciprocal-rank fusion. Exact identifiers, titles, apps, and URLs receive deterministic boosts. Generated summaries never outrank source evidence by default.

### Interface

- Menu-bar utility with a real main window.
- Menu bar: status, pause/resume, search, forget recent, settings, quit.
- Global search panel: 760 × 620 points, centered, keyboard-first.
- Main window: 1120 × 760 default, 840 × 560 minimum.
- Sidebar: Search, Timeline, Activity, Settings.
- Result grid: three columns at default width.
- Detail: screenshot canvas, provenance inspector, 96-point bottom timeline.
- SF Pro, SF Symbols, dynamic system surfaces, one system-indigo accent.
- 4-point spacing grid and fixed radius/motion tokens.

No third-party visual component framework is used. Reusable controls live in MemoryDesignSystem and require previews, keyboard states, accessibility labels, and screenshot fixtures.

## Stable contracts

Exact definitions are in [10-contracts-and-fixtures.md](10-contracts-and-fixtures.md):

- CaptureEnvelope
- MediaChunk
- SearchableFrame
- TextSpan
- EnrichmentArtifact
- SearchRequest and SearchResult
- TimelineSlice
- AccessPolicy
- DeletionTombstone
- ProcessingJob

Contract changes require a schema/migration version, fixture updates, previous-version compatibility tests, and an ADR when semantics change.

## Phased execution

| Phase | Stories | Outcome | Exit gate |
|---|---|---|---|
| 0 Foundation | LM-001–008 | Project, contracts, fixtures, spikes, first HEVC chunk | Defaults validated; release build works offline |
| 1 Native UI | LM-009–016 | SwiftUI shell, menu bar, tokens, onboarding | UX spec, keyboard, VoiceOver, light/dark pass |
| 2 Capture/store | LM-017–028 | Adaptive capture, privacy preflight, HEVC, GRDB | Eight-hour soak; zero excluded captures; kill-safe |
| 3 Text recall | LM-029–038 | AX, OCR, FTS5, filters | Recall@5 ≥ 0.90; lexical p95 < 300 ms |
| 4 Recall product | LM-039–048 | Search grid, detail, timeline, deletion | Lamp-today journey; timeline p95 < 200 ms |
| 5 Visual recall | LM-049–055 | MobileCLIP, flat vectors, hybrid ranking | Visual Recall@10 ≥ 0.80; hybrid p95 < 750 ms |
| 6 Trust/lifecycle | LM-056–064 | Retention, SQLCipher, export, forensic deletion | Zero-network and deletion proofs pass |
| 7 Agent memory | LM-065–071 | CLI, MCP, policies, audit | No policy leakage; offline stdio MCP |
| 8 Activity/audio | LM-072–079 | Heatmap, app totals, optional WhisperKit | Analytics reconcile; audio separately deletable |
| 9 Hardening | LM-080–086 | Dogfood, soak, install/rollback runbooks | All definition-of-done evidence attached |

Privacy fixtures begin in Phase 0. Privacy is not deferred to Phase 6.

## Agent operating protocol

The implementation agent must:

1. Read this plan, the active category plan, [10-contracts-and-fixtures.md](10-contracts-and-fixtures.md), and the active LM story.
2. Work on exactly one LM story at a time.
3. Confirm dependencies in phase-state.json.
4. Add or update fixtures and tests with implementation.
5. Run story commands and attach evidence paths to phase-state.json.
6. Append measurements, failures, and durable lessons to progress.md.
7. Create an ADR before changing a fixed architecture decision, privacy boundary, contract, or model.
8. Never mark a story complete from inspection alone.
9. Never waive privacy, deletion, integrity, or offline tests.
10. Stop for direction if a change expands scope, adds runtime networking, or weakens privacy/recovery.
11. Follow [14-goal-thread-runbook.md](14-goal-thread-runbook.md): checkpoint after every story and use `blocked_human` for actions that require TCC, credentials, physical interaction, or subjective acceptance.

The agent may automatically fix failures within the active story. It may not silently redesign later phases.

## Global invariants

- No runtime cloud service, account, or networking.
- No App Sandbox workaround that weakens capture/privacy semantics; use minimal entitlements, Hardened Runtime, TCC, owner-only files, and signed-helper Keychain ACLs.
- No telemetry, crash upload, update check, favicon request, or remote model.
- No raw keystroke or clipboard persistence.
- No media write before privacy preflight and recheck.
- No composited-display capture. Every persisted pixel must belong to the uniquely resolved, policy-approved foreground window and current capture epoch.
- No hidden recording state.
- No agent bypass of AccessPolicy.
- No deletion that leaves source or derived content.
- No generated statement presented without evidence.
- No silent model or dependency download.
- No Screenpipe or Coast code copied.
- No phase advances with failing privacy or integrity gates.

## Definition of done

1. Five normal workdays without disruptive resource use.
2. Exact and visual retrieval meet thresholds.
3. Search, screenshot detail, and timeline provide Coast-style recall.
4. Pause, exclusions, retention, deletion, and export survive failure tests.
5. Normal use makes zero outbound connections.
6. Database text is SQLCipher-encrypted and media protection is described accurately.
7. Activity analytics reconcile with captured intervals and do not claim productivity.
8. Agents retrieve bounded history without unrestricted archive access.
9. Installation, permissions, migration, rollback, export, and recovery are rehearsed.
10. UI passes keyboard, VoiceOver, light/dark, and screenshot review.
11. Every LM story is complete or removed through an ADR.
12. Every remaining Coast fidelity difference is documented.

## Research basis

- [Coast product](https://coast.app/)
- [Coast FAQ](https://coast.app/faq)
- [Coast privacy](https://coast.app/privacy)
- [Coast terms](https://coast.app/terms)
- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit)
- [Apple AVAssetWriter](https://developer.apple.com/documentation/avfoundation/avassetwriter)
- [Apple VideoToolbox hardware encoding](https://developer.apple.com/documentation/videotoolbox/kvtvideoencoderspecification_enablehardwareacceleratedvideoencoder)
- [Apple Vision OCR](https://developer.apple.com/documentation/vision/recognizing-text-in-images)
- [Apple Core ML](https://developer.apple.com/documentation/CoreML)
- [Apple MobileCLIP](https://github.com/apple/ml-mobileclip)
- [GRDB](https://github.com/groue/GRDB.swift)
- [SQLite FTS5](https://www.sqlite.org/fts5.html)
- [Official MCP Swift SDK](https://github.com/modelcontextprotocol/swift-sdk)
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- [Apple macOS Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Screenpipe behavioral reference](https://github.com/screenpipe/screenpipe)
