# DeepShelves build progress

This file is append-only. Each story records measurements, failures, and durable implementation lessons needed by a replacement goal thread.

## 2026-08-27 — LM-001 started

- Preflight: Apple Silicon (`arm64`), macOS 26.5, Xcode 26.5 (17F42), 163 GiB free.
- GitHub CLI is authenticated as `boovines`; `boovines/deepshelves` was created with private visibility and configured as `origin`.
- XcodeGen 2.46.0 was installed as the pinned bootstrap generator. All LM-001 Swift package dependencies are local, so project generation and compilation require no dependency network access.
- The source planning collection was copied byte-for-byte into `Docs/Plan/`; that committed snapshot becomes canonical at the LM-001 checkpoint.

## 2026-08-27 — LM-001 passed

- The first Xcode project probe found an incomplete first-launch installation (`DVTDownloads.framework` missing). `xcodebuild -runFirstLaunch` repaired the installation automatically; no H0 human gate was needed.
- XcodeGen emits a disposable `LocalMemory.xcodeproj`; the committed `LocalMemory.xcworkspace` points to it. Generated project data and DerivedData remain ignored.
- Tests initially failed because an integration bundle inherited a test host path based on the target name while the app product has a human-readable name. Removing the unnecessary app-host dependency made the integration suite logic-only and stable.
- Debug unit, integration, privacy, and performance tests pass. The release app, CLI, and MCP targets compile with Swift 6 strict concurrency and warnings as errors.
- A fresh no-local clone regenerated the project, passed privacy smoke and all tests, and completed the release build with automatic package resolution disabled. All packages in this checkpoint are local.
- Stable checkpoint revision: `refs/tags/checkpoints/LM-001`. Evidence: `Results/LM-001/build.txt`.

## 2026-08-27 — LM-002 blocked at H1

- Fixed bundle IDs now use `com.justinhou.deepshelves.localmemory` with `.cli` and `.mcp` helper suffixes.
- All three products are configured for Hardened Runtime, App Sandbox off, Swift 6, macOS 15 minimum, and the same `$(AppIdentifierPrefix)com.justinhou.deepshelves.shared` Keychain access group. No network entitlement is present.
- `ArchivePathProvider` creates the canonical `~/Library/Application Support/LocalMemory/` tree with directory mode 0700 and publishes file mode 0600 for owning writers. Deterministic temporary-root tests pass.
- Privacy smoke, affected tests, and the unsigned release build pass. The signed-posture proof is intentionally fail-closed while `security find-identity -v -p codesigning` reports zero valid identities.
- Human gate H1 is required. Resume from `HUMAN-ACTION.md` and `Results/LM-002/H1-preflight.txt`.

## 2026-08-27 — LM-002 H1 resume attempt

- The user believed signing setup might be complete, but the authoritative identity probe still returned zero valid identities. Keychain contained no Apple Development certificate, Xcode's active production-account list was empty, and no provisioning profiles existed.
- Apple’s current Xcode help confirms the sequence: add the Apple Account in Accounts settings, select the team, open Manage Certificates, click the lower-left Add button, and choose Apple Development. `HUMAN-ACTION.md` now records this exact flow.
- A read-only computer-use inspection was abandoned because the ChatGPT Computer Use permission prompt remained incomplete; it is not part of H1 and no additional human gate was created.

## 2026-08-27 — LM-002 H1 resolved

- The user created an Apple Development certificate for Personal Team `NS5L7NNR8U`, but `security find-identity` initially still returned zero because the login/system keychains only contained Apple’s expired 2023 WWDR intermediate.
- The leaf certificate’s issuer is WWDR G3. Apple’s official G3 certificate was downloaded from `https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer`, verified as SHA-256 `dcf21878c77f4198e4b4614f03d696d89c66c66008d4244e1b99161aac91601f`, and added to the login keychain. This repaired the trust chain without importing a private credential.
- `security find-identity -v -p codesigning` now reports one valid Apple Development identity. The project is fixed to team `NS5L7NNR8U`; signed-product verification resumed.

## 2026-08-27 — LM-002 H1 Keychain authorization pause

- The signed scheme initially launched app, CLI, and MCP `codesign` operations concurrently, causing three identical Keychain dialogs to stack. The build was interrupted and the verifier now signs three explicit schemes sequentially.
- The user reported that entering a password did not dismiss the frontmost prompt. No signing process remains, so the visible prompts are orphaned and safe to dismiss. This is distinct from the now-valid certificate trust chain.
- The prompt requires the `login` keychain password—normally the current Mac login password, but potentially an older Mac password if the login keychain became out of sync. Do not use the Apple Account password and do not reset/delete the keychain.
- A clean sequential rerun is pending direct login-keychain unlock verification under H1.

## 2026-08-27 — LM-002 passed

- H1 was completed by unlocking the existing `login` keychain; no reset or credential migration was required. The sequential verifier signed the app, CLI, and MCP helper with Apple Development identity `5F2CF76A05528002A43A04B748E50F81D795A4E9`.
- All three signed products verify strictly, carry Hardened Runtime, share `NS5L7NNR8U.com.justinhou.deepshelves.shared`, and carry neither App Sandbox nor client/server network entitlements. The project fixes team `NS5L7NNR8U`, its three bundle IDs, and macOS 15.0 deployment.
- `ArchivePathProviderTests` prove the archive tree is mode `0700`, published files are mode `0600`, and caller-supplied root names cannot escape Application Support.
- Full Xcode tests, privacy smoke, and unsigned Release build passed. Test and release scripts must not run concurrently because both call XcodeGen on the same `.xcodeproj`; a parallel gate attempt produced a harmless destination-exists race, and the release gate passed when rerun sequentially.
- Acceptance evidence is recorded in `Results/LM-002/entitlements.txt`.

## 2026-08-27 — LM-003 passed

- `MemoryContracts` now owns the V1 Foundation-only vocabulary for capture, media, searchable frames, text, enrichment, bounded search, stable result pages, timeline gaps/transitions, agent policies, deletion tombstones, and recoverable processing jobs. Runtime pixel buffers are explicitly omitted from serialization.
- `ContractJSON` is the canonical boundary codec. It emits sorted canonical JSON, lowercase UUID strings, and RFC 3339 UTC timestamps with exactly millisecond precision; unknown additive fields are ignored while unknown enums and noncanonical timestamps fail closed.
- Validation fixes normalized coordinates to upper-left-origin `0...1`, media intervals to half-open and at most 30 seconds, archive locators to relative non-traversing paths, agent history to 30 days, agent sessions to 24 hours, result bounds to 100, and automatic job attempts to three. Empty agent allowlists mean no content.
- Search pages sort by fused score descending, capture time descending, then lowercase UUID lexical order. Timeline members sort chronologically and excluded/protected/policy-uncertain gaps reject application identity.
- Eleven synthetic CC0 V1 fixtures are manifest-pinned by SHA-256. `scripts/check-contracts.sh` rebuilds the fixture generator, reproduces every byte, verifies every manifest hash, and runs 21 focused behavior/compatibility tests.
- The full repository suite passes 27 tests with zero failures; privacy smoke and unsigned offline Release build pass. Evidence: `Results/LM-003/contracts.json`.

## 2026-08-27 — LM-004 passed

- The canonical dependency/model SBOM now pins 21 components by exact version and commit, records license text hashes, artifact sizes/SHA-256 values, linkage scope, runtime-fetch policy, and an update procedure. Forty-one source, binary, and model artifacts total 402,123,412 bytes.
- The SQLCipher-maintained GRDB 7.11.1 fork is paired with SQLCipher.swift 4.18.0 and its package-declared XCFramework digest. This is the current supported SwiftPM shape for the fixed GRDB/SQLCipher architecture; database integration remains owned by LM-017/S5.
- Official MCP Swift SDK 0.12.1 currently declares EventSource and HTTP/conformance dependencies. The upstream package, EventSource, and swift-nio are recorded but forbidden from shipping. LM-068 must form an audited official-source stdio-only local target and prove the release helper links none of them.
- Argmax OSS 1.1.0 contains model-download configuration and an optional server build. It remains forbidden from shipping until optional audio creates a local-model-only target with `BUILD_ALL` disabled. The 19-file `small.en` 217 MB variant is pinned but remains off and build-time-install-only.
- Apple's six-file MobileCLIP-S0 Core ML pair and the official tokenizer/reference source are byte-pinned. The model license is research-only and excludes commercial product use; the private research build may evaluate it, but redistribution or commercial release requires a different grant or approved model decision.
- XcodeGen 2.46.0, Core ML SDK, Swift Testing, XCTest, and XCUIAutomation are tied to Xcode 26.5 build 17F42. Apple-licensed Xcode is installed separately rather than placed in the dependency cache.
- A fresh cache fetched and verified all 41 artifacts. The offline verifier then passed with `curl` exported as a failing function, proving that `--offline` issued no network call. Full tests increased from 27 to 33 and pass; contract fixtures, privacy smoke, Release build, and linked-binary scans of app/CLI/MCP all pass.
- Stable checkpoint: `refs/tags/checkpoints/LM-004`. Evidence: `Results/LM-004/dependencies.json`.

## 2026-08-27 — LM-005 passed

- The signed Release S1 harness uses one long-lived single-window `SCStream`, public-API AX-to-`SCWindow` resolution, revocable capture epochs, a final focus/policy/window/dimension/epoch admission check, and metadata-only typed gaps for uncertainty. H2 was verified against the final binary: Screen Recording and Accessibility are both granted.
- An early one-hour run showed that wall-clock rollover at 30 seconds can yield approximately 30.56-second QuickTime duration because the final ScreenCaptureKit sample interval extends the asset. Production rollover is therefore 29 seconds while the contract remains at most 30 seconds; boundary crash points 28/29/30 recovered at 28.045/29.053/29.560 seconds.
- A later rehearsal stopped advancing after about nine minutes because an asynchronous `SCShareableContent` refresh never completed. The production refresh provider now has a two-second fail-closed timeout, 30-second duplicate-suppression/replacement lease, and token ownership so a late completion cannot clear a newer lease. A 15-minute rehearsal and the final hour both advanced continuously beyond the former failure point.
- Final active results: 2,458/2,458 eligible transitions correct within one second, 352 excluded/unresolved transitions, 2,341 stale/policy frames rejected, zero contamination, zero backpressure drops, zero writer errors, and 351 sleep/wake cycles. Mean/p95 CPU was 3.948%/8.5%, max RSS 97.094 MB, storage 43.808 MB/hour, and random decode p95/p99 12.615/16.654 ms.
- Final static results: mean/p95 CPU 0.773%/1.1%, max RSS 85.188 MB, storage 0.519 MB/hour, ten 30-second heartbeat frames, zero contamination/backpressure/writer errors.
- All 2,419 referenced active/static assets passed HEVC and duration validation. Thirty forced-termination points produced playable HEVC artifacts, with maximum recovered duration 29.56 seconds. A separate 30-second Time Profiler trace was recorded without perturbing the canonical resource samples.
- The production defaults are frozen by 13 unit tests and one hardware-HEVC integration test. The full 47-test suite, 11 contract fixtures, privacy smoke, and universal offline-capable Release build pass. No 1,680-pixel, 0.5 fps, or HEIC fallback was used. Evidence: `Results/LM-005/report.json`, `Decisions/0001-capture-media.md`, and `Benchmarks/Results/S1/20260827T173516Z/`.

## 2026-08-27 — LM-006 passed

- The S2 harness projects only bounded, public Accessibility attributes, suppresses secure-field values, associates observations with the resolved window, and enforces both a 45 ms caller cutoff and the AX messaging timeout. Its live validation inspects only DeepShelves' synthetic window; it does not read or persist personal content from installed applications.
- The canonical 250-fixture AX corpus was 100% useful with 0.025 ms traversal p95. All 25 signed live probes were useful with 11.681 ms p95 and no timeout or capture-thread blocking.
- Apple Vision recovered all 800 words at IoU at least 0.5 across 200 locally rendered fixtures, including all 150 high-contrast fixtures. The stable AX-first merge left zero duplicate normalized tokens and lost zero ground-truth tokens.
- All 500 Safari/Chromium/Firefox structural adapter fixtures detected the correct sanitized host. Private mode suppressed 60/60 cases, and URL-unavailable site-rule cases suppressed 60/60 within the same decision frame. URL normalization removes credentials, query, and fragment components.
- The exclusion/private/background corpus evaluated 1,920 media, thumbnail, text, title, URL, vector, cache, and log slots with zero persisted prohibited artifacts. Named app coverage is represented honestly as installed inventory plus deterministic structural fixtures; Edge was absent and used fixture validation only.
- The full 54-test suite, 11 contract fixtures, privacy smoke, universal offline Release build, release binary audit, and signed S2 evidence checker pass. No fallback was needed by the canonical corpus. Evidence: `Results/LM-006/report.json` and `Benchmarks/Results/S2/20260827T191035Z/`.

## 2026-08-27 — LM-007 passed

- The selected MobileCLIP-S0 image and text Core ML encoders, tokenizer vocabulary/merges, and integrity manifest are compiled into `MemoryEnrichment`. Startup streams and verifies all 12 artifact hashes before model loading; the signed Release benchmark ran under an explicit `deny network*` sandbox and permits no runtime fetch.
- Packaged/reference cosine parity measured 1.0 for image and 0.99999988 for text. Across 500 locally rendered frozen frames and 100 frozen queries, real Core ML image/text p95 latency was 1.546/7.919 ms, visual Recall@10 was 1.0, and the single-job actor produced zero capture-timer intervals over 100 ms. The packaged resources occupy 112,239,644 bytes and enrichment max RSS was 351.609 MB.
- Mapping the entire 1,024,000,128-byte Float16 vector file made the first implementation fast but raised RSS to roughly 1.7 GB. The accepted scanner page-aligns bounded read-only `mmap` chunks, converts Float16 with vImage, scores with Accelerate, applies `MADV_DONTNEED`, and unmaps immediately. At one million 512-dimensional vectors it measured 618.043 ms p95 and 637.555 ms p99 unfiltered, 64.117 ms p95 over 100,000 filtered candidates, and 2.875 MB incremental RSS.
- Accelerate and scalar scoring differ by at most 0.00001371 with identical stable top-k ordering. Header/payload validation detects truncation before returning any result. Exact scan passed, so the documented HNSW fallback was not used.
- An intermediate `FileHandle`/`Data` hashing loop retained excessive memory during benchmark sampling; a reusable one-megabyte POSIX read buffer fixed the measurement without weakening full-file SHA-256 verification. A bare newly signed CLI helper was also immediately killed by the OS on this Personal Team setup, so S3/S4 correctly used the already validated signed app container; helper-signing architecture remains in the later helper story rather than being redesigned here.
- MobileCLIP's recorded license permits this private research evaluation but not redistribution or commercial use. Any such release requires a different grant or approved model decision.
- The full 58-test suite, 11 contract fixtures, privacy smoke, universal offline Release build, release-binary audit, and canonical S3/S4 evidence checker pass. Evidence: `Results/LM-007/report.json` and `Benchmarks/Results/S3S4/20260827T193136Z/`.

## 2026-08-28 — LM-008 passed

- S5 validates GRDB 7.11.1 over SQLCipher 4.18.0 with WAL, a random 32-byte Keychain key, 100 raw-file sentinels, five concurrent roles, 10,000 modeled crash points, and four forced process crashes. Encrypted p95 was 9.4265 ms versus 9.345083 ms plaintext, an overhead fraction of 0.00871. No sentinel appeared before deletion, every crash recovered consistently, and the real seeded HEVC fixture decoded before deletion but no matching decodable media remained afterward.
- Separate Personal Team helper executables cannot reliably claim the app's Keychain group. The plan-authorized fallback is fixed in ADR 0002: encrypted CLI/MCP access is provided by `--cli` and `--mcp` modes of the signed app executable. Standalone launchers have no Keychain entitlement, while unsigned and mismatched-access probes both fail with `errSecMissingEntitlement`.
- The pure SwiftUI `LazyVGrid` rehearsal stalled at distant card 5,468 for more than 120 seconds. ADR 0003 applies the authorized narrow fallback: only the 10,000-card hot collection uses `NSCollectionView`; the panel, detail, timeline, state, tokens, and accessibility remain SwiftUI/native. Signed Release XCUITest measured 43.040 ms warm and 260.190 ms cold focus, 10.905 ms initial-render p95, 58.728 fps fast-scroll p95, 129.188 MB maximum RSS, 0.014 ms thumbnail feedback, 18.296 ms full-frame settle, and zero stale screenshots.
- H0 UI Automation was resolved by user approval. The canonical signed XCUITest also passed resize, light/dark appearance, VoiceOver projection, keyboard navigation, and 40%-expanded pseudo-localization without clipped critical controls.
- S7 separates cache-only build closure from deny-all runtime closure because nesting Xcode/SwiftPM's own sandbox inside `sandbox-exec` fails before compilation on this macOS version. Release inputs are materialized from the verified local cache with automatic resolution disabled; the signed app/CLI/MCP journey runs under `deny network*` and recorded zero DNS, TCP, UDP, HTTP, QUIC, or denied shipping attempts. A positive sandbox control recorded one denial, all nine local journey stages completed, and all 27 regular shipping files have complete source/version/license/hash/update provenance.
- MobileCLIP-S0 is now classified as a bundled shipping dependency for this private research build. Its research-only license remains a hard restriction against redistribution or commercial use without a different grant or approved model decision.
- The final gates pass: 57 XCTest unit tests plus 4 Swift Testing unit tests, 7 integration tests, 4 privacy tests, and 1 performance test; 11 contract fixtures; privacy smoke; universal offline-capable Release build; signed posture; release binary audit; and all three canonical spike checkers. Evidence: `Results/LM-008/report.json`, `Benchmarks/Results/S5/20260827T224019Z/`, `Benchmarks/Results/S6/20260827T222621Z/`, and `Benchmarks/Results/S7/20260827T223755Z/`.

## 2026-08-28 — LM-009 passed

- H0 required macOS Developer Mode in addition to the already granted Accessibility permission. After the user enabled it, `/usr/sbin/DevToolsSecurity -status` reported Developer Mode enabled and signed Release XCUITest automation resumed.
- `LocalMemoryAppLifecycle` is an actor-backed, owner-only state machine for recording, paused, permission-required, disk-full, and indexing states. Relaunch restores the runtime state but deliberately never restores main-window visibility; malformed state fails closed to permission-required. The parent directory and state file are verified as modes `0700` and `0600`.
- The app now composes one shared lifecycle model across a native SwiftUI `MenuBarExtra` and singleton `Window` scene. The default menu-bar utility launch has zero main windows. Explicit test/evidence launch modes open the singleton scene through SwiftUI's `openWindow` action, avoiding dependence on remembered scene state while preserving the production no-window launch invariant.
- The menu status uses symbol shape, fill, label, action label, and availability—not color alone—to represent every fake runtime state. The popover exposes foreground-window-only status, pause/resume or recovery action, search, timeline, bounded forgetting, main window, Settings, and Quit.
- `Results/LM-009/LM-009.mov` is a nine-second, app-window-only H.264 recording of synthetic state transitions. The capture script resolves the layer-zero window by process ID and records only that window, so no personal desktop or installed-application content is present.
- The final gates pass: 57 XCTest unit tests plus 9 Swift Testing unit tests, 7 integration tests, 4 privacy tests, 1 performance test, 4 signed Release UI tests, 11 contract fixtures, privacy smoke, universal offline-capable Release build, signed posture, release binary audit, and whitespace validation. Evidence: `Results/LM-009/report.json`.

## 2026-08-28 — LM-010 passed

- The main scene now uses native `NavigationSplitView` and `List(selection:)` behavior with a 1120 × 760 default, 840 × 560 minimum, a 184-point governed sidebar, and a 264-point inspector that disappears below 900 points. The separate native Settings scene is 680 × 560 and exposes Capture, Privacy, Storage, Search, Agents, and About sections.
- Durable navigation restoration is owner-only (`0700` parent and `0600` file), restores both section and selected moment, and fails closed on malformed data. Multiple SwiftUI startup callers share one restoration task and re-check restored state after awaiting it; early menu or command navigation is queued so restoration cannot overwrite explicit user intent.
- Native list selection was required for visible selection and accessibility semantics. Deterministic evidence sizing is applied only after the SwiftUI/AppKit window attachment and restoration pass, preventing scene restoration from racing the requested default or minimum geometry.
- On macOS 26, UI Automation requires an interactive device-owner authentication for the current session. Timed-out clients can remain registered in the user-scoped `testmanagerd` and then stall ordinary XCTest. The safe recovery is to verify that no app, Xcode, or `xctest` process remains, clear only that exact user-scoped daemon, and launch one authenticated test runner.
- Six PID-owned, layer-zero, window-only screenshots cover the main and Settings scenes in light and dark appearances, with the main scene at both default and minimum geometry. All content is synthetic. The full 62-test XCTest unit suite, 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 7 signed Release UI tests, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation pass. Evidence: `Results/LM-010/report.json`.

## 2026-08-28 — LM-011 passed

- `MemoryDesignSystem` now owns the complete plan-11 foundation: 12 semantic color tokens, the 4/8/12/16/24/32 spacing scale, 6/10/14 radii, 28/32/36 control heights, one-physical-pixel hairlines, seven native type roles, and 100/180/260 ms motion roles.
- Colors bridge only to dynamic AppKit semantic sources. The test suite resolves the window token under Aqua and Dark Aqua and proves the values differ; the canonical catalog contains no hex, RGB, calibrated, or light-only color encoding.
- Reduce Motion retains governed timing but replaces movement transitions with opacity. Increased Contrast raises selected-surface opacity from 0.16 to 0.28 and hairlines from one to two physical pixels. `MemoryTokenReader` derives both policies and display scale directly from SwiftUI's system environment.
- `Results/LM-011/tokens.json` is byte-identical to the runtime-generated, sorted canonical snapshot and is enforced by the design-system tests. The full 69-test XCTest unit suite, 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation pass. Evidence: `Results/LM-011/report.json`.
