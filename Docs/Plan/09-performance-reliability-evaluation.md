# Performance, Reliability, and Evaluation

## Outcome

Prove that the application can run every day without becoming noisy, slow, storage-hungry, or untrustworthy. Quality gates are local, repeatable, and block phase completion.

## Budgets

Initial targets on an Apple Silicon laptop:

| Metric | Target |
|---|---|
| Normal capture CPU | Under 6% average |
| Idle capture CPU | Under 1.5% average |
| Resident memory | Under 750 MB without optional audio model |
| Default storage growth | Under 20 GB/month |
| Capture-to-searchable p95 | Under 10 seconds |
| Lexical search p95 | Under 300 ms |
| Hybrid search p95 | Under 750 ms at one million frames |
| Result-detail open p95 | Under 200 ms |
| Wake-to-capture recovery | Under 60 seconds |
| Eight-hour capture soak | Zero crash, corruption, exclusion leak, or unbounded queue |

These are gates, not promises, until measured on the target Mac.

## Local observability

Expose a diagnostics page:

- Capture state and last successful frame
- Accessibility/OCR/embedding queue depths
- Frames accepted, deduplicated, dropped, and excluded
- Database size, media size, and growth rate
- Index/model versions
- Search latency percentiles
- Permission status
- Last error code

All metrics remain local. No telemetry endpoint exists.

## Test layers

### Unit

- Focused AX window to unique `SCWindow` resolution
- Capture-epoch revocation and stale-buffer rejection
- Query parsing
- Exclusion matching
- Deduplication
- Retention selection
- Ranking fusion
- Redaction
- Data migrations

### Contract

- Capture envelope
- Enrichment jobs
- Search request/response
- CLI JSON
- MCP tools and policies

### Integration

- Single-window ScreenCaptureKit filter to epoch-scoped SQLite/media
- Background/excluded sentinel absence across media and derived artifacts
- Accessibility and OCR fallback
- FTS/vector indexing
- Deletion cascade
- SwiftUI to shared domain actors
- MCP to policy-filtered search

### End-to-end

- Permission onboarding
- Demonstrate that a sensitive background/adjacent window is absent from the approved foreground capture
- Record a known workflow
- Search exact and visual content
- Open and scrub timeline
- Exclude an app/domain
- Forget recent history
- Query through MCP

### Soak and fault

- Eight-hour normal workday
- 72-hour synthetic accelerated capture
- Sleep/wake cycles
- Process kills at every pipeline stage
- Disk full
- Permission revocation
- Display reconnect
- Rapid focus/window/URL/filter/resize races with prior-window sentinels
- Database migration interruption
- Model unavailable or corrupt

## Fixture strategy

Never use the user’s live archive in automated tests.

- Synthetic screenshots containing known text and objects
- Scripted macOS fixture applications/windows
- Accessibility-tree fixtures
- Audio samples with known transcripts
- A generated 30-day database
- A million-capture stress database for query planning
- A privacy fixture containing fake credentials and denied applications

Record fixture licenses and avoid real personal data.

## Retrieval evaluation

Maintain a versioned query relevance set and run it whenever:

- OCR changes
- Embedding model changes
- Ranking weights change
- Session grouping changes
- Database schema/index changes

Report per query class rather than one aggregate score. A semantic improvement must not regress exact identifiers, dates, or application filters.

## Energy and storage profiling

Measure:

- Capture frequency by trigger
- Duplicate suppression rate
- OCR/model duty cycle
- Media bytes per active hour
- Index bytes per capture
- Thumbnail cache hit rate
- Thermal and battery impact

Profile on battery and power. Defer low-priority OCR/embedding work under thermal pressure or low battery, and resume safely later.

## Release and rollback

For personal use:

- Generate the Xcode project from pinned project.yml and build a local .app bundle with xcodebuild.
- Keep a stable bundle identifier and development signature for TCC permissions.
- Produce a versioned backup before schema migration.
- Keep one previous known-good build.
- Provide a health command and read-only export command through LocalMemoryCLI.

A paid Apple Developer membership is unnecessary for local development/testing. Notarization becomes relevant only if distributing the application.

## Agent implementation discipline

ADR 0006 requires runtime-host provenance in every performance report. On the owner's
laptop, application, ScreenCaptureKit, ImageIO, VideoToolbox, and hardware-media runtime are
prohibited. Safe unit/model/static/compile/snapshot measurements may guide implementation
but cannot satisfy live CPU, energy, WindowServer, interaction, or wall-clock soak gates.
Those checks accumulate in the H9 ledger and run once on the isolated validation Mac at
LM-064.

For every phase:

1. Read the master plan and the category plan.
2. Select one narrow milestone.
3. Add or update fixtures first.
4. Implement the smallest vertical slice.
5. Run relevant unit, integration, privacy, and performance gates.
6. Record decisions in an ADR and measured results in progress.md.
7. Mark a milestone complete only when its acceptance criteria pass.
8. Stop and request a decision when changing architecture, privacy boundary, or license posture.

No agent may waive a privacy or data-loss test to advance the phase.

## Completion gate

- Three-workday dogfood run without archive corruption. Codex remains stopped for the
  entire observation window; the app records only its bounded local diagnostics, and the
  user manually resumes the goal afterward.
- All fidelity journeys pass
- Retrieval targets pass on the private benchmark
- Privacy suite proves excluded/deleted data absence
- Offline runtime verified
- Performance budgets met or explicitly accepted with measured exceptions
- Fresh-machine installation and permission onboarding rehearsed
- Recovery/export runbook successfully followed

## Sources

- [Apple Instruments](https://developer.apple.com/tutorials/instruments)
- [Apple developer program requirements](https://developer.apple.com/help/account/membership/programs-overview)
- [Screenpipe published operating targets](https://github.com/screenpipe/screenpipe)
