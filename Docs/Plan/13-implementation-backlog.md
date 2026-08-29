# Dependency-Ordered Implementation Backlog

## How to execute this backlog

This is the sole story order for the first complete build. Execute it through [14-goal-thread-runbook.md](14-goal-thread-runbook.md). Complete one story at a time unless two adjacent stories explicitly say they may run in parallel. Each story must leave the repository buildable, add automated tests proportional to its behavior, and attach evidence to `phase-state.json`.

A story is complete only when:

1. Its dependencies are `passed`.
2. Release build, affected unit/integration tests, and privacy smoke test pass.
3. The stated evidence artifact exists and contains the git revision.
4. New failure behavior has a user-visible state or documented recovery path.
5. `progress.md` records measurements and durable decisions.

Use `xcodegen generate`, then pinned `xcodebuild` schemes. CI-equivalent local commands are recorded in the project README once LM-001 creates it. Architecture/privacy/contract changes require an ADR and human direction; a failing test alone is not authorization to relax a gate.

ADR 0006 adds one narrow scheduling exception without changing completion: an implementation
dependency may be consumed when its upstream story is technically `blocked` solely on a
runtime check prohibited on this laptop, has `implementationReadiness: ready`, and names H9
as its `deferredValidationGate`. The downstream story may use only unit, model, static,
compile, and deterministic snapshot verification. It must record runtime-only checks in the
H9 ledger and may not call those proof classes substitutes for runtime evidence. A deferred
story remains incomplete and blocked until H9 supplies its original acceptance evidence.
After LM-064, every dependency must be `passed`; implementation readiness is insufficient.

## Phase 0 — Foundation and measured defaults

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-001 | Create/init `/Users/justinhou/Development/deepshelves`, create the private GitHub repository `deepshelves` and `origin`, snapshot this planning set into `Docs/Plan/`, and create `project.yml`, workspace, app/CLI/MCP targets, local packages, test targets, formatter/linter config, and schemes. | H0 if Xcode preflight fails; H8 if GitHub authentication is unavailable | Fresh private clone generates/builds offline from pinned cache; plan snapshot is committed/pushed; `Results/LM-001/build.txt`. |
| LM-002 | Fix bundle IDs, developer signing, Hardened Runtime, App Sandbox off, minimal entitlements, shared signed-helper Keychain group, minimum macOS 15, and owner-only archive path helper. | LM-001; H1 if signing/Keychain UI is required | Entitlement/signature snapshot proves the fixed posture and no network capability; `Results/LM-002/entitlements.txt`. |
| LM-003 | Implement `MemoryContracts` V1 types, validation, JSON codecs, clock/coordinate semantics, and compatibility fixtures from plan 10. | LM-001 | Valid fixtures round-trip byte-semantically; malformed enums, paths, intervals, and policies fail closed; `Results/LM-003/contracts.json`. |
| LM-004 | Pin GRDB/SQLCipher, MCP Swift SDK, model/runtime, XcodeGen, and test dependencies; generate license/hash manifest and offline dependency cache instructions. | LM-001 | Dependency audit has source/version/license/hash; shipping binary has no update/telemetry package; `Results/LM-004/dependencies.json`. |
| LM-005 | Run S1 foreground-window resolver/filter-epoch/dedup/media spike and record production constants. | LM-002, LM-003; H2 if not already satisfied | Resolver, stale-frame, pixel-contamination, media, and resource gates pass or the listed nonprivacy fallback is adopted through ADR; `Decisions/0001-capture-media.md`. |
| LM-006 | Run S2 target-window AX/OCR/browser/privacy spike and publish supported-context matrix. | LM-002, LM-003, LM-005 | Coverage, target association, latency, OCR, browser, and zero-leak gates pass; `Results/LM-006/context-matrix.json`. |
| LM-007 | Run S3 and S4 MobileCLIP/exact-vector spikes; package the chosen model resources. | LM-003, LM-004 | Model parity/recall plus million-vector latency/memory gates pass or listed fallback ADR exists; `Results/LM-007/report.json`. |
| LM-008 | Run S5–S7 SQLCipher, native-UI, and offline spikes; freeze measured defaults in configuration tests. | LM-004, LM-005, LM-006, LM-007 | Encryption/crash, UI responsiveness, and zero-network gates pass; ADRs and `Results/LM-008/report.json`. |

## Phase 1 — Native shell and design system

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-009 | Implement SwiftUI application composition, app lifecycle actor, menu-bar extra, main-window scenes, and no-main-window launch. | LM-008 | Relaunch/state tests pass; menu status always represents the fake runtime; UI recording `LM-009.mov`. |
| LM-010 | Implement main split navigation, scene restoration, minimum/default geometry, detail inspector collapse, and Settings scene. | LM-009 | XCUITest restores section/selection across relaunch and works at minimum size; screenshots in both appearances. |
| LM-011 | Implement semantic color/type/spacing/radius/motion tokens in `MemoryDesignSystem`, including Reduce Motion and Increased Contrast behavior. | LM-009 | Token snapshots match plan 11 and contain no hard-coded light-only colors; `Results/LM-011/tokens.json`. |
| LM-012 | Implement shared search field, filter tokens, status badge, result card, evidence snippet, permission row, empty/error/progress views, and confirmation sheet. | LM-011 | Complete component state preview/snapshot matrix including long localization and keyboard focus. |
| LM-013 | Build deterministic screenshot harness at 1x/2x, light/dark/Increased Contrast, default/minimum sizes, plus reviewed baselines for shared controls. | LM-012 | Baselines reproducibly render with zero unapproved diffs; `Results/LM-013/snapshot-index.html`. |
| LM-014 | Implement resumable four-step onboarding, permission explanations/actions, truthful storage/privacy copy, and live fake preview. | LM-010, LM-012 | Denied/granted/revoked paths are XCUITested; no repeated system prompt loop; VoiceOver transcript attached. |
| LM-015 | Implement configurable global shortcut and 760×620 AppKit-backed search panel with focus, display memory, escape behavior, and shared navigation state. | LM-010, LM-012 | Warm/cold appearance gates from S6 pass; shortcut collision produces a recoverable setting state. |
| LM-016 | Complete sidebar destinations, standard empty/loading/error states, keyboard map, menus, tooltips, and first full accessibility audit. | LM-013, LM-014, LM-015 | All plan-11 keyboard paths and VoiceOver smoke pass in English and pseudo-localization; `Results/LM-016/a11y.txt`. |

## Phase 2 — Capture and canonical persistence

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-017 | Implement `MemoryStore` archive bootstrap, V1 GRDB schema, foreign keys, WAL configuration, migrations, and deterministic test store. | LM-003, LM-008 | Fresh/migrate/interrupted-migrate tests pass; schema matches plan 10; `Results/LM-017/schema.sql`. |
| LM-018 | Implement owner-only directory creation, validated relative paths, partial/atomic file writer, startup orphan recovery, quarantine, and integrity hashes. | LM-017 | Fault fixtures at rename/commit boundaries recover without searchable corruption; `Results/LM-018/faults.json`. |
| LM-019 | Implement ScreenCaptureKit permission probe, `SCShareableContent` refresh, pixel-buffer lifetime rules, and restartable `SCStream` that has no eligible target by default. | LM-005, LM-017 | Fake/real lifecycle tests pass across grant/revoke/display change; no composited-display frame can be delivered or persisted. |
| LM-020 | Implement `NSWorkspace`/AX foreground monitor and strict `WindowResolver` mapping foreground PID/AX identity/geometry to one eligible main-display `SCWindow`. | LM-006, LM-019 | 500-transition fixture resolves the exact window; ambiguous/minimized/protected/secondary-display cases emit typed metadata-only gaps and zero pixels. |
| LM-021 | Implement Safari/Chrome/Arc-Dia/Edge/Firefox address-field adapters tied to the resolved target window, with conservative URL normalization/private-context output. | LM-006, LM-020 | Supported-context matrix meets accuracy; target association is unique; query/fragment/credentials never serialize. |
| LM-022 | Implement compiled application/site/private-window `PrivacyPolicy`, non-removable self/login/permission exclusions, editable password-manager/private defaults, precedence, prefilter decision, final epoch recheck, and non-content audit. | LM-017, LM-020, LM-021 | Exclusion and background-sentinel fixtures persist zero prohibited artifacts; property tests fail closed on missing/ambiguous target or URL context. |
| LM-023 | Implement coarse input-class `ActivityMonitor`, five-minute idle state, sleep/wake/session-lock handling, and prohibit key/clipboard value capture. | LM-020 | State transitions pass fake-clock tests; binary/string scan finds no raw key or clipboard payload fields. |
| LM-024 | Implement revocable `WindowCaptureEpoch`, single-window `SCContentFilter` updates, stale-buffer rejection, measured acceptance/dedup, and bounded newest-frame backpressure. | LM-019, LM-022, LM-023 | Rapid focus/filter/URL/resize races never accept prior/background pixels; correct new target begins within one second p95; overload drops stale candidates first. |
| LM-025 | Implement downscale and ≤30-second, single-epoch, fixed-dimension HEIC-keyframe `MediaWriter`, canonical manifest, exact frame locators, per-frame/chunk hashes, atomic directory finalization, and explicit injection of the pinned software-only codec. Remove ImageIO, AVAssetWriter, and VideoToolbox from the shipping path. | LM-018, LM-024 | Every chunk has one target/epoch/dimension; logical duration/frame ordering, real software-HEIC encode/decode, exact-frame lookup, integrity, retained-only replacement, retention removal, and termination fixtures pass beneath the encoder-service tripwire without executing a hardware video encoder. |
| LM-026 | Implement atomic coordinator among epoch/policy identity, ready HEIC manifests/assets, frame rows, and retryable jobs; no row points to staging, corrupt, missing, or mismatched media. Add the append-only V2 frame-locator migration. | LM-017, LM-022, LM-025 | Injected crashes/focus races restore invariants and never expose stale/mismatched targets; unreferenced published directories reconcile deterministically; `Results/LM-026/state-machine.json`. |
| LM-027 | Connect visible pause/resume, foreground-window-only status, launch-at-login, idle, sleep/wake, target gaps, permission loss, low-disk stop, and safe restart. Persist exact resolver gaps; retain exact visible low-disk/archive/process stop causes within the canonical `processStopped` timeline class. | LM-009, LM-023, LM-026; H3 only when a user-initiated `SMAppService.register()` returns `requiresApproval` | UI agrees within 250 ms; no hidden capture; every unavailable target/stop reason creates its exact typed projection and canonical gap; interrupted recording never resumes before complete reconciliation. |
| LM-028 | Run eight-hour office soak plus accelerated focus/filter/fault/pixel-contamination suite using the pinned software-only HEIC runtime. Measure encode/decode CPU, memory, corpus size, exact-frame decode, temporary residue, and projected 30-day retention; fix leaks, unbounded queues, corrupt manifests/assets, resolver errors, and recovery failures. | LM-027 | Resource/storage/decode budgets pass under the encoder-service tripwire or a measured nonprivacy tuning ADR is adopted; automated scans find zero background/adjacent/excluded/stale sentinel or codec temporary residue in every canonical/derived location; `Results/LM-028/soak-report.md`. The real wall-clock/runtime portion is an H9 ledger item under ADR 0006; LM-028 remains blocked until it passes. |

## Phase 3 — Text enrichment and lexical recall

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-029 | Implement bounded Accessibility snapshot extraction for the accepted foreground window, with time/node limits and supported-role text projection. | LM-006, LM-026 | AX coverage and latency gates pass; raw trees are released and not persisted. |
| LM-030 | Normalize AX strings, remove secure-field values, collapse duplicate nodes, attach bounds/provenance, and emit `TextSpan`s. | LM-029 | Secure-field and duplicate fixtures pass with no sentinel leakage; normalization goldens attached. |
| LM-031 | Implement Vision OCR fallback with orientation/scale correction, confidence/language/bounds, job leasing, cancellation, and thermal-aware single concurrency. | LM-026, LM-006 | Full OCR accuracy/latency fixture passes without delaying capture; retry/permanent failure states render. |
| LM-032 | Implement deterministic AX/OCR span merge and approved title/app/URL projections; discard transient raw observations. | LM-030, LM-031 | Duplicate/loss gates from S2 pass; output stable across insertion order. |
| LM-033 | Generate hash-verified 480-pixel HEIC searchable thumbnails asynchronously through the pinned software codec and recover/rebuild missing thumbnails. | LM-026 | Real-HEIC aspect/orientation/sRGB color fixtures pass beneath the encoder-service tripwire; runtime tamper, deletion, and missing-file rebuild tests pass. |
| LM-034 | Implement durable prioritized `EnrichmentScheduler` leases, three-attempt policy, version invalidation, backlog reporting, idle/power/thermal throttles. | LM-017, LM-032, LM-033 | Kill/restart and priority tests prove capture transitions precede heartbeats; UI backlog is accurate. |
| LM-035 | Implement canonical `merged_text_records` and explicit transactional external-content FTS5 maintenance for approved screen text, title, app, host/path, and a separately reserved future transcript source. | LM-032, LM-034 | FTS docsize row inventory and integrity match ready frames after insert/update/delete/rebuild; suppressed inputs and stale terms never publish. |
| LM-036 | Implement deterministic locale-aware parser for time phrases, explicit app/site tokens, quoted text, and remaining lexical query. | LM-003 | 100 query parse goldens pass; ambiguous phrases remain text and hidden filters are impossible. |
| LM-037 | Implement lexical `SearchEngine` over the six LM-035 FTS fields: policy filters, BM25, deterministic boosts, evidence spans, stable keyset cursor, cancellation, and pagination. | LM-035, LM-036 | Ordering/cursor/property tests pass; prohibited frames never enter candidates; CLI-independent API. |
| LM-038 | Tune against golden judgments without editing labels; publish text Recall@5/latency and fix until phase gate passes. | LM-037 | Recall@5 ≥0.90 for text-app-site-time subset and p95 <300 ms; reproducible report `Results/LM-038/retrieval.json`. |

## Phase 4 — Recall product: search, detail, and timeline

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-039 | Bind shared `SearchEngine` state to global panel/main Search section with debounced cancellation and exactly-once settled ordering. | LM-015, LM-038 | Rapid typing never shows stale results; warm/slow/error XCUITest fixtures pass. The fixtures are an H9 ledger item under ADR 0006; LM-039 remains blocked until their isolated-Mac runtime passes. |
| LM-040 | Implement visible parser tokens, app/site pickers, date interval controls, query examples, filter removal, and URL/app autocomplete from approved metadata. | LM-036, LM-039 | Every applied filter is visible/removable and round-trips; keyboard/VoiceOver interaction passes. |
| LM-041 | Implement adaptive lazy result grid, pagination, selection, thumbnail cache, card provenance, and no-result/indexing states. | LM-012, LM-033, LM-039 | 10k-card S6 performance and accessibility announcements pass; no stale thumbnails. The production runtime checks are an H9 ledger item under ADR 0006; LM-041 remains blocked until they pass. |
| LM-042 | Implement evidence rendering for AX/OCR/app/title/URL sources, component-debug overlay behind a diagnostics flag, and honest no-summary behavior. | LM-041 | Each golden result cites source evidence; no generated or unsupported claim is displayed. Production UI/accessibility inspection is an H9 ledger item under ADR 0006; LM-042 remains blocked until it passes. |
| LM-043 | Implement detail canvas and actor-owned exact-source-HEIC decode/cache through the pinned software codec with zoom/pan, frame stepping, corrupt-media recovery, and export-moment action. | LM-025, LM-041 | Decode latency gates pass under the encoder-service tripwire; rapid selection cancellation shows the exact requested frame; runtime tamper, corrupt file, or manifest mismatch yields recovery UI. |
| LM-044 | Implement interval query that returns ordered `TimelineSlice`s, typed gaps, transitions, frame summaries, and day/zoom pagination. | LM-027, LM-037 | 24-hour fixture returns exact order/durations; DST, sleep, excluded, and stopped gaps remain explicit. |
| LM-045 | Implement 96-point timeline rail, low-res immediate scrub/full-frame dwell, gap patterns, zoom levels, and accessibility-list projection. | LM-043, LM-044 | S6 scrub budget, keyboard transitions, VoiceOver list, and screenshot baselines pass. |
| LM-046 | Implement Timeline section, date navigation, app transition labels, selected-result context, and safe Revisit to app/approved URL only. | LM-045 | Day navigation/restoration and locale/DST tests pass; Revisit never restores form state or bypasses policy. |
| LM-047 | Implement Forget Moment/Range product flow backed by provisional deletion state: hide targets immediately, queue verified physical rewrite, expose progress/failure. | LM-026, LM-043, LM-045 | Confirmation defaults Cancel; hidden targets never reappear in search/helper during processing; crash resumes. |
| LM-048 | Run complete text recall journeys (“find exact phrase”, “what app/site”, “lamp today” lexical fallback, timeline context, revisit, forget) and accessibility review. | LM-040–LM-047 | Journey recording, screenshots, p95 UI timings, and zero policy leakage attached; phase defects closed. |

## Phase 5 — Visual and hybrid recall

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-049 | Add bundled compiled MobileCLIP-S0 image/text encoders, tokenizer/preprocessing, integrity manifest, startup verification, and typed unavailable state. | LM-007, LM-034 | Offline model parity/hash/inference tests reproduce S3; corrupted model never yields results. |
| LM-050 | Implement thermal/power-aware image embedding jobs for searchable frames, version invalidation, deterministic normalization, and backlog UX. | LM-049 | Capture budgets remain within gate; fixtures produce stable normalized vectors; failed jobs retry correctly. |
| LM-051 | Implement append-safe model-versioned Float16 vector files, SQLite offsets/norms, checksums, compaction, crash-tail repair, and complete rebuild. | LM-017, LM-050 | Truncate/duplicate/compaction property tests pass; no result reads invalid tail or wrong model hash. |
| LM-052 | Implement memory-mapped, chunked, cancellation-aware Accelerate exact cosine scan with prefiltered offset sets and stable top-k. | LM-051 | Scalar parity and S4 100k/500k/1M latency/memory gates pass. |
| LM-053 | Add visual-only text-query embedding, candidate retrieval, visual evidence labels, and visual mode to shared SearchEngine. | LM-049, LM-052 | Visual-only Recall@10 ≥0.75 baseline; filters and AccessPolicy apply before result projection. |
| LM-054 | Implement RRF with `k=60`, exact-field boosts, dedup/grouping rules, stable pagination, and settle-once hybrid UI behavior. | LM-037, LM-053 | Hand-computed fusion fixtures pass; deterministic ordering; lexical results do not repeatedly jump. |
| LM-055 | Tune hybrid retrieval on frozen labels and run full million-frame benchmark/reindex/recovery. | LM-054 | Visual Recall@10 ≥0.80, hybrid nDCG/Recall non-regressive, hybrid p95 <750 ms; `Results/LM-055/retrieval.json`. |

## Phase 6 — Trust, lifecycle, and forensic deletion

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-056 | Implement app exclusion settings, rule ordering, test-this-context preview, immediate policy reload, and typed timeline gaps. | LM-022, LM-016 | Change-during-capture tests persist nothing after effective time; excluded app never appears in UI/helper. |
| LM-057 | Implement full browser/private policy matrix and permission-health monitor; fail closed with user-visible reason whenever protected URL context is unavailable. | LM-021, LM-056 | Supported browser matrix and revoke/private/version-change fixtures have zero leakage. |
| LM-058 | Implement exact 30-day retention and 20-GB cap worker, oldest-ready-HEIC-chunk ordering, low-disk emergency stop, progress, and deterministic fake-clock tests. | LM-026, LM-047 | Bound counts manifest plus frame assets, never knowingly exceeds cap after cleanup, protects active staging, and cascades derived rows/files. |
| LM-059 | Enable SQLCipher in all builds, generate/store/recover Keychain key for signed targets, encrypt WAL/temp, and provide explicit unrecoverable-key reset flow. | LM-008, LM-017 | S5 sentinel/ACL/performance tests pass; logs never contain key; reset requires typed destructive confirmation. |
| LM-060 | Complete transactional retained-frame HEIC chunk replacement for moment/range deletion, vector compaction, thumbnail/text removal through the LM-035 explicit FTS deletion boundary, tombstone recovery, and old-directory disposal. Never re-encode retained source frames. | LM-047, LM-051, LM-059 | Every delete crash point resumes/rolls back; only nondeleted frame assets remain integrity-valid, decodable, and searchable; deleted sentinels are absent from manifests, files, merged records, spans, and FTS docsize rows. |
| LM-061 | Build forensic deletion verifier scanning DB/WAL/HEIC manifests and frame assets/thumbnails/vectors/logs/exports/helper projections plus codec temporary residue for seeded sentinels. | LM-060 | All deletion fixture sentinels and frame IDs are absent after checkpoint/vacuum, old-directory disposal, and codec-process termination; signed report `Results/LM-061/deletion.json`. |
| LM-062 | Implement explicit export (manifest + selected original evidence), integrity check, quarantine review, archive repair, and documented full-reset/recovery flows. | LM-018, LM-060 | Export is self-describing and policy-bounded; corrupted fixtures repair/quarantine without silent data invention. |
| LM-063 | Implement automated deny-all-network run, socket/DNS instrumentation, binary/dependency/model audit, and build-time-only dependency bootstrap verification. | LM-049, LM-059, LM-062 | Every normal journey produces zero outbound attempt; reproducible audit `Results/LM-063/offline.json`. |
| LM-064 | On the isolated validation Mac, execute the complete ADR-0006 H9 runtime ledger, then run the trust gate: exclusions, private browsing, pause, retention, encryption copy, delete moment/range/all, export, key loss, and permission revocation. | LM-056–LM-063 implementation-ready; H9 | Every deferred runtime item passes and its source story is promoted in dependency order; all privacy fixtures pass; UI claims match verified protection; five-minute manual trust checklist recording and `Results/LM-064/isolated-validation-ledger.json` are attached. |

## Phase 7 — Bounded agent memory

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-065 | Extract read-only query/timeline/detail projections into `SharedQueryKit` used unchanged by app and helper targets. | LM-055, LM-064 | Same request fixture produces byte-equivalent ordered projection in app tests and helper tests. |
| LM-066 | Implement persisted user-created `AccessPolicy`, maximum intervals/results/expiry, app/site allowlists, image toggle, Keychain-held local capability, and revocation. | LM-003, LM-065 | Empty allowlists mean none; expiry/revocation concurrent with query fails closed; property tests prove subset results. |
| LM-067 | Implement signed `local-memory` CLI commands for status, search, timeline, get-moment, and image-resource with JSON V1, required policy for content, and stable exit/error codes. | LM-002, LM-066 | Golden CLI fixtures, policy denial, cancellation, pagination, offline execution, and malformed-input tests pass. |
| LM-068 | Implement official Swift SDK stdio MCP server for status/search/timeline/get-moment, with no HTTP listener, arbitrary SQL, or mutation tools. | LM-067 | Protocol inspector and two independent MCP clients pass offline; port scan shows no listener. |
| LM-069 | Implement MCP image resources with opaque IDs, explicit policy opt-in, bounded dimensions/bytes, expiry, cancellation, and deleted-resource invalidation. | LM-068 | Unauthorized/expired/deleted IDs fail without path disclosure; byte/dimension limits enforced before decode response. |
| LM-070 | Implement Agent Access settings, policy creation/review/revoke, helper install diagnostics, and content-free local audit entries. | LM-016, LM-067, LM-069 | User can explain scope before approve; no forever/unrestricted option; audit contains query hash not query/content. |
| LM-071 | Run adversarial policy suite: prompt-like queries, traversal, cursor tamper, huge limits, races, revoked policies, excluded content, and client disconnects. | LM-070 | Zero policy leakage or mutation; helpers stay under resource limits; `Results/LM-071/agent-security.json`. |

## Phase 8 — Activity and optional audio

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-072 | Derive durable foreground activity intervals from approved context/activity signals with typed gaps and exact elapsed-duration semantics. | LM-023, LM-064 | Seven-day fixture totals reconcile exactly; exclusions/idle/sleep never count as active. |
| LM-073 | Implement accessible day/week hourly heatmap with local calendar/DST correctness and Timeline drill-through. | LM-072, LM-016 | Visual and table projections match fixture minutes; repeated/missing DST hours labeled. |
| LM-074 | Implement per-application totals, unrecorded total, range controls, and neutral explanatory copy; prohibit productivity scoring. | LM-072, LM-073 | Totals plus gaps equal selected elapsed interval; snapshot/copy audit has no evaluative score language. |
| LM-075 | Add separately consented microphone/system-audio capture experiment, independent toggle/status/permission, and no audio default. | LM-064; H4 only if user elects optional audio | Visual app remains complete without permission/model; status clearly distinguishes audio from screen capture. |
| LM-076 | Bundle or explicitly install fixed WhisperKit `small.en` resources without silent download; transcribe locally with versioned jobs and thermal scheduling. | LM-075 | Offline hash/inference/latency fixtures pass; capture budget non-regressive; absent model has actionable state. |
| LM-077 | Populate the separately reserved LM-035 transcript field with timestamped transcript spans and expose them through FTS/evidence/timeline with audio-source labels and no silent semantic summary. | LM-035, LM-044, LM-076 | Transcript search locates labeled fixtures within timestamp tolerance; evidence distinguishes transcription and never merges it into approved screen text. |
| LM-078 | Implement separate audio retention/delete/export controls and cascading deletion from chunks, transcripts, FTS, and helper projections. | LM-060, LM-077 | Delete-audio-only and delete-all forensic sentinels vanish from every projection; visual retention remains correct. |
| LM-079 | Run activity/audio reconciliation, permission, privacy, thermal, and optional-feature removal gate. | LM-074, LM-078 | Activity exact, audio local/deletable, and build with audio disabled remains fully functional; report attached. |

## Phase 9 — Hardening and personal release

| ID | Deliverable | Depends on | Acceptance and evidence |
|---|---|---|---|
| LM-080 | Add release performance telemetry that remains local: signposts, bounded rotating logs, diagnostic export, energy/memory/storage/index backlog dashboards. | LM-079 | No content in metrics/logs; overhead below 1% CPU; diagnostic bundle privacy snapshot passes. |
| LM-081 | Complete three real workdays of personal dogfood, logging search failures, false exclusions, resource discomfort, crashes, and UX friction; fix release blockers. Before observation begins, Codex must checkpoint LM-080, enter the H5 pause, end its active turn, and remain fully stopped until the user manually returns. | LM-080; H5 | Three-workday report, resource percentiles, issue dispositions, zero known privacy/deletion blocker, and evidence that no Codex automation, heartbeat, polling, or monitoring ran during observation. |
| LM-082 | Run 72-hour accelerated software-HEIC capture/enrichment/search/retention/delete fault soak with clock advancement, codec-process termination, and disk pressure. | LM-081 | Under the encoder-service tripwire, no unbounded growth, codec temporary residue, corrupt searchable manifest/asset state, stuck leases, exclusion leak, orphan staging/ready directory, deleted sentinel, or unrecoverable restart. |
| LM-083 | Rehearse signed fresh install, first launch offline, permission grant/deny/revoke, launch-at-login, OS update smoke, helper installation, and complete uninstall/data-preserve choices. | LM-082; H6 | Screen recording and command transcript cover every path; uninstall never deletes archive without explicit choice. |
| LM-084 | Rehearse database/model migration, interrupted migration, archive backup/export, binary rollback, newer-schema refusal, corrupt-media quarantine, and Keychain loss reset. | LM-083 | Previous release archive upgrades once, rollback behavior is explicit, and no destructive recovery is implicit. |
| LM-085 | Freeze retrieval golden report and conduct final keyboard, VoiceOver, contrast, localization, minimum-window, five core journey, and UI screenshot review. | LM-084; H7 | All numeric gates and plan-11 surfaces pass; remaining Coast fidelity differences documented and user review recorded. |
| LM-086 | Write personal release/runbook, dependency/model update procedure, troubleshooting, privacy claims, backup caveat, known limits, and final `phase-state.json`; tag release candidate. | LM-085 | Every LM story is passed or ADR-removed, all evidence links resolve, release build works under deny-all network policy. |

## Phase-state format

`phase-state.json` is machine-readable and append-safe:

```json
{
  "schemaVersion": 1,
  "activeStory": "LM-001",
  "stories": {
    "LM-001": {
      "status": "pending",
      "startedAt": null,
      "completedAt": null,
      "gitRevision": null,
      "evidence": [],
      "notes": null,
      "blockedReason": null,
      "requestedHumanGate": null,
      "resumeProbe": null
    }
  }
}
```

Allowed statuses are `pending`, `active`, `blocked`, `blocked_human`, and `passed`. At most one story is `active`. `blocked` requires a concrete technical failing gate, evidence path, attempted fallbacks, and requested decision. `blocked_human` is limited to the enumerated gates in plan 14 and requires `HUMAN-ACTION.md` plus a `resumeProbe`; neither status is a synonym for “difficult.” ADR-0006 runtime deferral may add `implementationReadiness: "ready"` and `deferredValidationGate: "H9"` to a blocked story. Those fields affect scheduling only and never satisfy completion or release acceptance.
