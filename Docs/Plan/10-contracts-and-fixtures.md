# Contracts and Fixture Corpus

## Purpose

This document removes ambiguity at package boundaries. These contracts are the vocabulary shared by capture, storage, enrichment, search, UI, CLI, and MCP. Internal implementations may change; identifiers, time semantics, provenance, deletion behavior, and serialized helper responses may not change without a migration.

All wall-clock timestamps are UTC `Date` values encoded as RFC 3339 with fractional seconds. All media offsets and durations are integer milliseconds. All rectangles use normalized display coordinates from 0 through 1 with the origin at the upper-left. Primary identifiers are random UUIDs encoded as lowercase strings.

## Package boundaries

| Package | Owns | May depend on |
|---|---|---|
| `MemoryContracts` | Types, enums, validation, JSON codecs | Foundation only |
| `MemoryStore` | GRDB records, migrations, media/vector files, deletion transactions | Contracts, GRDB |
| `MemoryCapture` | Screen/AX/activity/browser signals and media writer | Contracts, Store, Apple frameworks |
| `MemoryEnrichment` | OCR, text merge, thumbnails, MobileCLIP, optional audio | Contracts, Store, Apple frameworks, model runtimes |
| `MemorySearch` | Query parser, FTS, vector scan, fusion, timeline queries | Contracts, Store, Accelerate |
| `MemoryAgentAccess` | Access-policy enforcement and redacted projections | Contracts, Search |
| `MemoryDesignSystem` | Tokens and reusable native controls | SwiftUI/AppKit only |
| `MemoryTestSupport` | Builders, clocks, fixture loaders, fake streams | All packages in test targets only |

No lower-level package imports an app target. Capture never imports Search or UI. Search never reads media files directly; it requests media locators from Store. Agent access cannot issue raw SQL.

## Core contracts

The canonical Swift definitions use `Codable`, `Sendable`, `Equatable`, and explicit initializers. Database-only fields remain in `MemoryStore` records rather than leaking into domain values.

### `CaptureEnvelope`

One accepted visual observation before it becomes durable media.

| Field | Type | Rule |
|---|---|---|
| `id` | `UUID` | Stable across all derived artifacts |
| `capturedAt` | `Date` | UTC wall time |
| `continuousTimeNanoseconds` | `UInt64` | Ordering within a boot; never shown as wall time |
| `displayID` | `UInt32` | Main display containing the approved target in V1 |
| `captureEpochID` | `UUID` | Revocable epoch created after a successful single-window filter update |
| `targetWindowID` | `UInt32` | Uniquely resolved `SCWindow.windowID` |
| `surfaceKind` | enum | `foregroundWindow` is the only pixel-bearing V1 case |
| `pixelSize` | `PixelSize` | Persisted dimensions after downscale |
| `foreground` | `ForegroundContext` | Bundle ID and target-window identity required for pixel-bearing capture |
| `browser` | `BrowserContext?` | URL stored only after policy approval |
| `activity` | `ActivityState` | `active`, `recentlyActive`, or `idle` |
| `reason` | `CaptureReason` | `visualChange`, `contextChange`, `heartbeat`, `manual` |
| `policyDecisionID` | `UUID` | Links to the final allow decision |
| `pixelBuffer` | non-Codable handle | In-process only; must be released after media commit |

`ForegroundContext` contains `bundleID`, localized application name, optional process ID, window title, and normalized window bounds. `BrowserContext` contains browser family, normalized origin (`scheme`, lowercase host, optional non-sensitive path), and an `isPrivateContext` flag. Query strings, fragments, and credential components are discarded before persistence.

A `CaptureEnvelope` with pixels is valid only when `surfaceKind == foregroundWindow`, the target/epoch match the active filter, and the final policy decision allows that same target. Metadata-only gaps do not contain a `CaptureEnvelope` or pixel buffer.

### `MediaChunk`

| Field | Type | Rule |
|---|---|---|
| `id` | `UUID` | File identity |
| `captureEpochID` | `UUID` | Exactly one approved foreground-window epoch |
| `targetWindowID` | `UInt32` | Same target for every frame in the chunk |
| `relativePath` | `String` | Relative manifest path under the archive root; no traversal |
| `startedAt`, `endedAt` | `Date` | Half-open interval `[start, end)`, maximum 30 seconds |
| `codec` | enum | `hevcMain` for legacy V1; `heicKeyframes` for canonical V2 |
| `container` | enum | `quickTimeMovie` for legacy V1; `heicKeyframeDirectory` for canonical V2 |
| `width`, `height` | `Int` | Positive, maximum long edge 1920 |
| `frameCount` | `Int` | Matches committed frame locators |
| `byteCount` | `Int64` | Manifest plus all referenced frame assets, verified before/after atomic directory rename |
| `sha256` | `Data` | SHA-256 of canonical manifest bytes; manifest carries each frame digest |
| `state` | enum | `writing`, `ready`, `rewriting`, `quarantined` |

A ready chunk is immutable. A canonical V2 chunk path ends in `/manifest.json`; sibling `frames/<frame-id>.heic` assets are the complete independently decodable source inventory. Removing a subset creates a replacement directory containing only retained assets, verifies it, atomically swaps references, records a tombstone, then deletes the old directory. V1 HEVC values remain decode-only compatibility cases.

### `HEICKeyframeManifest`

| Field | Type | Rule |
|---|---|---|
| `schemaVersion` | `Int` | Exactly `2` for this manifest contract |
| `chunkID` | `UUID` | Matches parent `MediaChunk.id` and path component |
| `captureEpochID` | `UUID` | One approved foreground-window epoch |
| `targetWindowID` | `UInt32` | Same target for every frame |
| `width`, `height` | `Int` | Fixed positive encoded dimensions, long edge ≤1920 |
| `frames` | `[HEICKeyframeEntry]` | Nonempty, strictly increasing logical time, unique IDs and paths |

Each entry carries `frameID`, `presentationTimeMS`, `relativePath` (`frames/<frame-id>.heic`), `byteCount`, and a 32-byte `sha256`. The canonical JSON bytes are hashed by the parent chunk. Missing, extra, reordered, substituted, duplicated, or corrupt assets fail verification and remain nonsearchable.

### `SearchableFrame`

| Field | Type | Rule |
|---|---|---|
| `id` | `UUID` | Same as capture ID |
| `captureEpochID` | `UUID` | Matches parent chunk |
| `targetWindowID` | `UInt32` | Matches parent chunk and approved context |
| `capturedAt` | `Date` | Search/timeline time |
| `chunkID` | `UUID` | Ready media chunk |
| `presentationTimeMS` | `Int64` | Logical ordering position in chunk |
| `mediaPath` | `String?` | Required for schema V2; exact source `media/.../frames/<frame-id>.heic` path |
| `thumbnailPath` | `String?` | 480-pixel HEIC, rebuildable |
| `foreground` | `ForegroundContext` | Approved projection |
| `browser` | `BrowserContext?` | Approved projection |
| `textState` | enum | `pending`, `ready`, `failed`, `suppressed` |
| `visualState` | enum | `pending`, `ready`, `failed`, `suppressed` |
| `isTransition` | `Bool` | True for immediate app/window/URL transition |
| `schemaVersion` | `Int` | Decoder compatibility |

### `TextSpan`

| Field | Type | Rule |
|---|---|---|
| `id`, `frameID` | `UUID` | Parent relationship |
| `source` | enum | `accessibility`, `visionOCR`, `transcript` |
| `text` | `String` | Unicode-normalized, whitespace-collapsed |
| `bounds` | `NormalizedRect?` | Required for OCR where available |
| `confidence` | `Float?` | 0...1 for OCR; absent for AX |
| `languageCode` | `String?` | BCP 47 where detected |
| `sensitivity` | enum | `normal`, `redacted`, `suppressed` |

Duplicate spans are merged using normalized text and overlap. Raw AX trees and raw OCR observations are not persisted.

### `EnrichmentArtifact`

| Field | Type | Rule |
|---|---|---|
| `id`, `frameID` | `UUID` | Stable artifact and parent IDs |
| `kind` | enum | `mergedText`, `thumbnail`, `visualVector`, `transcriptSegment` |
| `producer` | `ProducerVersion` | Name, semantic version, model hash |
| `createdAt` | `Date` | UTC |
| `payloadLocator` | enum | Inline DB row or validated relative file offset |
| `contentHash` | `Data` | Idempotency and corruption detection |
| `state` | enum | `ready`, `stale`, `failed`, `deleted` |

Artifacts are disposable projections. Their parent frame is the deletion authority.

### Search contracts

`SearchRequest` fields:

- `query: String`
- `interval: DateInterval?`, half-open
- `bundleIDs: Set<String>`
- `hosts: Set<String>`
- `mode: SearchMode` (`hybrid`, `textOnly`, `visualOnly`)
- `pageSize: Int`, clamped to 1...100
- `cursor: SearchCursor?`, an opaque signed local token
- `accessPolicy: AccessPolicy`

`SearchResult` fields:

- `frameID`, `capturedAt`, approved foreground and browser context
- `thumbnailLocator` and `mediaLocator`, never unrestricted absolute paths in MCP output
- `evidence: [SearchEvidence]` with source text/visual match and provenance
- component ranks and final fused score for debugging
- `nextCursor` only on a result page, not per result

Stable ordering is final score descending, capture time descending, then UUID lexical order. A cursor encodes the final ordering tuple and query fingerprint so pagination never skips equal-scored results.

### `TimelineSlice`

Contains interval, ordered frame summaries, explicit recording gaps, application transitions, and optional transcript markers. A gap has a typed reason: `paused`, `idle`, `excluded`, `permissionLost`, `filterFailed`, `sleep`, `processStopped`, `unresolvedWindow`, `ambiguousWindow`, `minimizedWindow`, `unsupportedDisplay`, `protectedSurface`, `noWindow`, or `unknown`. The UI must not interpolate across a gap.

A gap stores only start/end, reason, and an optional already-approved bundle ID. Excluded, protected, private, and policy-uncertain gaps contain no application identity, title, URL, text, thumbnail, vector, or media locator.

### `AccessPolicy`

| Field | Rule |
|---|---|
| `id`, `name` | Stable local identity and user-facing name |
| `allowedInterval` | Required for helper access; maximum 30 days |
| `allowedBundleIDs`, `allowedHosts` | Empty means none for agents, not all |
| `allowImageResources` | Defaults false |
| `maxResults` | Clamped to 1...100 |
| `expiresAt` | Required and maximum 24 hours for agent sessions |
| `createdByUser` | Must be true before MCP use |

The in-app UI uses a separate `OwnerAccess` capability and never serializes it. There is no “unrestricted” MCP policy.

### `DeletionTombstone`

Records deletion ID, requested interval/frame IDs, reason, request time, completion time, affected chunks/artifact counts, replacement chunk IDs, and a verification hash. It contains no deleted content. States are `planned`, `rewriting`, `committed`, `verified`, and `failed`. A crash resumes or rolls back from the last durable state.

### `ProcessingJob`

Contains job ID, parent frame/chunk ID, `kind`, priority, state, attempt count, next-attempt time, producer version, last error code, and lease expiry. States are `queued`, `leased`, `succeeded`, `retryableFailure`, `permanentFailure`, and `cancelled`. Leases make work recoverable after process death. Maximum automatic attempts are three.

## Durable schema

Schema version 1 contains these tables:

- `archive_meta(key PRIMARY KEY, value)`
- `media_chunks(id PRIMARY KEY, capture_epoch_id, target_window_id, relative_path UNIQUE, started_at, ended_at, codec, width, height, frame_count, byte_count, sha256, state)`
- `frames(id PRIMARY KEY, captured_at, monotonic_ns, capture_epoch_id, target_window_id, chunk_id, pts_ms, media_path, media_sha256, media_byte_count, thumbnail_path, bundle_id, app_name, window_title, window_x, window_y, window_w, window_h, browser_family, url_scheme, url_host, url_path, capture_reason, is_transition, text_state, visual_state, schema_version)`
- `text_spans(id PRIMARY KEY, frame_id, source, text, x, y, w, h, confidence, language_code, sensitivity)`
- `frame_fts` as FTS5 external-content index over approved merged text, title, app name, host, and path
- `artifacts(id PRIMARY KEY, frame_id, kind, producer_name, producer_version, model_hash, locator_kind, locator_value, content_hash, state)`
- `vector_offsets(frame_id PRIMARY KEY, model_hash, byte_offset, dimension, norm, state)`
- `activity_intervals(id PRIMARY KEY, started_at, ended_at, bundle_id, app_name, state, gap_reason)`
- `processing_jobs(id PRIMARY KEY, parent_id, kind, priority, state, attempts, next_attempt_at, producer_version, error_code, lease_expires_at)`
- `policy_decisions(id PRIMARY KEY, decided_at, bundle_id, host, private_context, result, matched_rule_id)`
- `access_policies(id PRIMARY KEY, encoded_policy, expires_at, created_by_user)`
- `deletion_tombstones(id PRIMARY KEY, encoded_tombstone, state)`
- `audit_events(id PRIMARY KEY, occurred_at, actor, action, policy_id, result_count, query_hash)`

Foreign keys are enabled. Frame-dependent rows cascade. FTS maintenance uses explicit transactions rather than implicit triggers so tests can observe each step. SQLCipher uses a Keychain-held 256-bit random key. WAL and temporary SQLite files must remain beside the encrypted database.

## Filesystem contract

    LocalMemory/
      database/archive.sqlite3
      media/YYYY/MM/DD/<chunk-uuid>/manifest.json
      media/YYYY/MM/DD/<chunk-uuid>/frames/<frame-uuid>.heic
      thumbnails/YYYY/MM/DD/<frame-uuid>.heic
      vectors/mobileclip-s0/<model-hash>.f16
      models/<model-name>/<model-hash>/...
      exports/<export-uuid>/...
      quarantine/...
      logs/local-memory.log

The archive root and all children are owner-only. Source-media writers use a hidden sibling staging directory, per-frame sibling partials, `fsync`, canonical-manifest validation, one no-replace directory rename, parent `fsync`, then database commit. Startup removes orphan staging directories, reconciles unreferenced ready directories, quarantines corrupt manifests/assets, repairs jobs, and never makes a corrupt artifact searchable.

## Serialization and compatibility

- JSON contract version `1` remains readable for legacy HEVC fixtures. Canonical HEIC archives, CLI, and MCP projections use version `2`.
- Unknown additive fields are ignored by older readers; unknown enum cases fail closed.
- Removing/renaming a field or changing time/filter semantics requires a new major contract version.
- Every database migration has forward, fresh-install, interrupted-migration, and previous-version read tests.
- Model changes create new artifacts alongside old ones; promotion occurs only after complete reindex and evaluation.

## Fixture corpus

All fixtures are synthetic, generated, or explicitly licensed and contain no personal data.

### Golden visual/text archive

- 500 screenshot frames across Safari, Chrome, Finder, Mail-like content, Calendar-like content, Terminal, code editor, PDF, spreadsheet, and settings screens.
- Light/dark appearances, Retina/non-Retina source sizes, overlapping windows, menus, sheets, notifications, video, and visually static pages.
- 100 adversarial surface scenes place machine-detectable sentinels in background password managers, notifications, private-browser windows, desktop/Dock/menu-bar regions, split-screen neighbors, and prior focused windows; none may appear in canonical or derived data.
- 75 explicit app/window/URL transitions and 30 typed gaps.
- AX snapshots for 250 frames and OCR ground truth polygons/text for 200 frames.
- 50 near-duplicate sequences for capture-dedup testing.
- 40 exclusion/private-context sequences plus 50 rapid filter-change races in which zero prohibited or stale-window pixels/text may persist.

### Retrieval judgments

One hundred queries with at least three independent relevance labels per query:

- 30 exact text/title/identifier queries
- 20 app/site/time-filter queries
- 25 visual/semantic descriptions such as “the yellow lamp I saw yesterday”
- 15 combined ambiguous queries
- 10 no-result/adversarial queries

Each query declares relevant frame IDs, graded relevance 0...3, expected filters, and forbidden results. Reports calculate Recall@5, Recall@10, nDCG@10, MRR, p50, p95, and p99 latency.

### Scale and failure fixtures

- Deterministic generators for 100,000, 500,000, and 1,000,000 frame rows and vectors.
- Media chunks truncated at header, middle, and tail; mismatched hashes; missing thumbnails and vector tails.
- Process termination before frame rename, before chunk-directory rename, after rename/before DB commit, and during retained-frame replacement.
- Permission revocation, display sleep, user switch, clock change, low disk, and model corruption.
- Seven-day activity intervals whose totals are independently calculated.

### UI fixtures

Deterministic stores for onboarding, empty archive, active capture, paused, permission lost, indexing backlog, search loading, no results, mixed results, corrupt media, deletion progress, activity gaps, and MCP policy approval. Screenshot baselines are captured at 1x and 2x in light/dark appearance and Increased Contrast.

## Fixture governance

- `Fixtures/manifest.json` records source, license, SHA-256, and expected semantic labels.
- Generated fixtures use a fixed seed and record generator version.
- Golden relevance or privacy labels cannot be changed in the same story as the implementation being scored unless the story explicitly corrects a fixture defect with review evidence.
- Performance runs write machine model, OS build, power mode, thermal state, build configuration, git revision, and raw samples.

## Contract exit gate

The contract layer is complete when codecs round-trip every fixture, invalid values fail with typed errors, version-1 compatibility tests pass, deletion cascades leave no recoverable fixture content, and CLI/MCP return the same ordered projections as the in-app search engine.
