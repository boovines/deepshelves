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

## 2026-08-28 — LM-012 passed

- `MemoryDesignSystem` now owns eleven native SwiftUI shared controls: search field, filter token/bar, capture status badge, result card, evidence snippet, permission row, empty/error/progress states, and destructive confirmation sheet. Feature code can compose these without inventing colors, type, spacing, radii, motion, or destructive-button behavior.
- The deterministic component matrix is the Cartesian product of 11 controls and 13 required variants, producing 143 unique scenarios. It covers normal, hover, pressed, focused, disabled, selected, loading, error, light, dark, Increased Contrast, long German localization, and explicit keyboard focus. A compiled `#Preview` gallery renders the same matrix.
- Search focuses on open and exposes an accessible clear control. Progress remains absent through 300 ms and becomes quiet inline status only after that threshold. Result cards enforce one-line titles, two-line evidence, and announce time, app, host, evidence type, and result position.
- Capture status always combines a unique icon with text and an accessibility label. Recording red remains reserved for the recording state; error chrome uses the warning semantic and destructive emphasis comes from the native destructive button role. Confirmation requires a truthful removal scope and consequence, and Cancel is the default keyboard action.
- `Results/LM-012/component-matrix.json` is byte-identical to the runtime-generated catalog. The full 76-test XCTest unit suite, 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation pass. Evidence: `Results/LM-012/report.json`.

## 2026-08-28 — LM-013 passed

- The snapshot harness uses an offscreen `NSHostingView`, explicit Aqua/Dark Aqua/Accessibility High Contrast Aqua appearance, an explicit 1× or 2× `NSBitmapImageRep`, and disabled animation. It never depends on the current display's backing scale or appearance.
- The canonical matrix contains 12 baselines: default 1120 × 760 and minimum 840 × 560 logical sizes, each at 1×/2× in light, dark, and Increased Contrast. All images are synthetic, local, and manifest-pinned; the total gallery is 2,028,566 bytes.
- Visual review found that the first minimum-size board compressed away search text and truncated the permission recovery action. Search now has layout priority, the permission row uses a narrow-safe vertical action layout, and the compact confirmation density keeps all eleven controls visible at 840 × 560 without clipping.
- `scripts/run-lm013-snapshots.sh --check` renders into a validated temporary directory and requires byte-for-byte equality for every PNG, the manifest, and the offline self-contained HTML index. The final rerender has zero unapproved diffs.
- The full 80-test XCTest unit suite, 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation pass. Evidence: `Results/LM-013/report.json` and `Results/LM-013/snapshot-index.html`.

## 2026-08-28 — LM-014 passed

- First launch now opens one 760 × 620 native four-step onboarding window and persists the exact current step in owner-only state. Completion closes onboarding, opens the main scene, and prevents the wizard from reopening on later launches.
- Screen Recording and Accessibility are the only onboarding permissions. Status is derived from capability probes, including an explicit revoked state; permission actions occur only after `Open System Settings`, and a persisted action ledger proves relaunch never generates another action or prompt.
- The privacy step states the fixed foreground-window-only guarantee verbatim and animates synthetic foreground/background fixtures into a saved-image preview containing only the foreground fixture. The ready step reports the menu-bar control, pause-shortcut posture, local archive, 30-day retention, 20-GB cap, and deliberately distinguishes future database encryption from current macOS/FileVault media protection.
- A `NavigationSplitView` detail can propagate an unbounded vertical proposal even when its outer window has a fixed frame. Bounding both the step region and footer to the 620-point content height keeps Back/Continue/Finish hittable in XCUITest; relying only on an outer frame allowed the footer to be laid out far below the clipped window.
- H0 UI Automation was resolved by approving the stable `.build/LM010DerivedData` runner. The canonical signed suite passed all 10 existing and onboarding UI tests, including denied/relaunch, granted/completion, and revoked/recovery paths. The full 86-test XCTest unit suite, 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation pass. Evidence: `Results/LM-014/report.json` and `Results/LM-014/voiceover.txt`.

## 2026-08-28 — LM-015 passed

- Option-Space is registered as a real system-wide shortcut through Carbon `RegisterEventHotKey`; Settings can switch to Command-Shift-K. Registration collisions produce the stable `LM-SHORTCUT-409` state and one recovery action, and the selected shortcut is persisted with `0700` parent and `0600` file permissions.
- Global search is a native 760 × 620 AppKit `NSPanel` with a 640 × 480 minimum. It uses the non-activating style while explicitly becoming key when invoked, focuses the search field, remembers the last display, and fails closed to a valid pointer/primary display when remembered geometry is unavailable.
- Search and the main scene share one `MainNavigationViewModel`. Selecting a result in the transient panel survives into the main scene, while Escape closes only the panel and preserves navigation state.
- The retained signed Release UI measurement recorded 54 ms cold and 8 ms warm presentation, below the frozen S6 gates of 400 ms and 150 ms. The canonical UI suite also invokes the panel with a real Option-Space event and verifies geometry, focus, filtering, Escape, shared navigation, collision recovery, and owner-only persistence.
- The final gates pass: 93 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 4 signed Release UI tests, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation. Evidence: `Results/LM-015/report.json`.

## 2026-08-28 — LM-016 passed

- The main shell now exposes Search, Timeline, Activity, and Settings through native sidebar selection plus Command-1/2/3/comma. Selection history supports Command-brackets, Command-F moves focus without breaking editable spaces, and the complete plan-11 moment vocabulary is present in native menus.
- A window-scoped AppKit event monitor supplies reliable Space, Return, Command-Return, Option-arrow, Command-Delete, and Escape behavior without stealing default actions from onboarding, Settings, or the global search panel. The first broad regression caught the panel Escape collision; scoping to the main window and attached sheets fixed it and a new onboarding Return regression prevents recurrence.
- Quick Look and confirmation sheets restore the selected-row keyboard path after dismissal. Forget Moment always opens truthful confirmation with Cancel as the default, and no global shortcut silently deletes data or changes recording state.
- Standard empty, delayed-loading, and recoverable-error projections reuse the shared design system. The three icon-only shell controls have labels, unique tooltips, and explicit 24-point minimum targets; semantic system fonts preserve the 11-point minimum body posture.
- Result rows announce time, application, approved host, evidence source, and position. Timeline exposes markers and a permission-loss gap as an accessibility list, while Activity exposes date/hour/recorded/gap values as a table projection.
- English and 40%-expanded pseudo-localized accessibility projections pass. Clock, named relative-day, and week-start behavior is verified through Foundation under `en_US` and `fr_FR`.
- The final gates pass: 101 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 20 signed Release UI tests, 11 contracts, the retained accessibility audit, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation. Evidence: `Results/LM-016/report.json` and `Results/LM-016/a11y.txt`.

## 2026-08-28 — LM-017 passed

- `ArchiveDatabase` now owns the application-lifetime GRDB writer. Production opens `database/archive.sqlite3` through a five-reader `DatabasePool` in WAL mode with foreign keys, full synchronous writes, a five-second busy timeout, file-backed temporary storage beside the database, and `0600` database/WAL/SHM permissions inside the existing owner-only archive tree.
- The append-only `v1_archive_schema` migration creates all 13 plan-10 logical tables and 12 query/scheduling indexes. Frame-owned text spans, artifacts, and vector offsets cascade; foreign-key integrity is exercised after a real deletion.
- `frame_fts` is an FTS5 external-content index over `frames.approved_text`, title, app, host, and path. The approved merged-text projection is database-only, and no implicit trigger exists: later enrichment/search work must maintain the index explicitly inside observable transactions.
- Forced interruption after all V1 statements but before migration commit rolls the complete logical schema back, leaves no applied identifier, and then resumes exactly once. A version-zero fixture remains readable across migration, while two deterministic in-memory stores produce byte-identical schema and metadata.
- `Results/LM-017/schema.sql` is exported from a freshly migrated store and validated against all canonical tables, external-content configuration, and the no-trigger invariant. The final gates pass: 108 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation. Evidence: `Results/LM-017/report.json` and `Results/LM-017/schema.sql`.

## 2026-08-28 — LM-018 passed

- `ArchiveRelativePath` validates both construction and decoding, accepts only six managed archive roots, and rejects absolute, tilde, backslash, NUL, dot, parent, empty, partial-suffix, unmanaged-root, and symlink-escape paths before any file operation.
- `ArchiveFileStore` writes an owner-only sibling partial without overwriting, synchronizes it, computes its SHA-256 and byte count, atomically promotes it, synchronizes the parent directory, and only then invokes the database commit. Ordinary failures clean the partial while the two injected crash boundaries preserve exactly the artifact startup recovery must reconcile.
- Startup recovery removes orphan partials, quarantines uncommitted or corrupt completed files, suppresses database and FTS projections for missing or invalid ready media, cancels related artifact work, requeues interrupted leases, and recursively repairs the archive tree to `0700` directories and `0600` files.
- The production LM-018 harness proves before-rename and after-rename/before-commit recovery, SHA-256 mismatch and missing-file quarantine, zero searchable corruption, traversal rejection, lease recovery, and owner-only permissions. The final gates pass: 117 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation. Evidence: `Results/LM-018/report.json` and `Results/LM-018/faults.json`.

## 2026-08-28 — LM-019 passed

- Screen recording permission is probed without requesting it. Shareable-content enumeration is a two-second bounded lease: retries stay suppressed for 30 seconds after timeout, a replacement lease may then begin, and a late completion from the old lease cannot clear or mutate the replacement.
- The lifecycle actor starts with no eligible target and therefore creates no stream. Permission loss, refresh failure, target disappearance, or ineligibility stops delivery; a stable target retains one long-lived stream, while a display change stops, refreshes, and restarts only that same eligible target.
- The production driver has only a `desktopIndependentWindow` filter construction. Its output adapter can create only foreground-window pixel-buffer leases, which strongly retain the in-process `CVPixelBuffer` until a media-commit closure or explicit non-persistent discard consumes the lease exactly once.
- The signed Release harness used the stable app identity and real TCC grant, refreshed real `SCShareableContent`, selected only the app's own eligible window, received one frame, restarted the stream for a display lifecycle change, received another frame, released both leases, persisted zero frames, and returned to no-target. The final gates pass: 126 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, and whitespace validation. Evidence: `Results/LM-019/report.json` and `Results/LM-019/lifecycle.json`.

## 2026-08-28 — LM-020 passed

- `NSWorkspaceForegroundApplicationMonitor` emits a monotonically sequenced initial state and foreground lifecycle transitions. Accessibility is inspected only after the frontmost application identity is known, with a 50 ms messaging timeout and public AX attributes; no private window-ID bridge or composited-display capture API exists in the shipping sources.
- A public AX top-level attribute is not universally exposed by SwiftUI windows. The signed probe therefore records the exact identity source: it prefers and cross-checks focused plus top-level windows when both exist, while a PID-validated focused `AXWindow` with role, subrole, bounds, and title is the public fallback. The resolver still requires AX/SCK PID and normalized geometry agreement before approval.
- `ForegroundCaptureTargetResolver` refreshes shareable content at most once per foreground transition, caches only that transition's result, and invalidates immediately when a selected window disappears. It returns the actual `SCWindow` only after strict identity and eligibility checks; every gap carries metadata and zero pixel payloads.
- The frozen 500-transition corpus resolves all 350 eligible cases to the exact window ID and emits 25 each of ambiguous, minimized, no-window, protected, unresolved, and unsupported-display gaps. All 150 gaps contain zero pixels. A signed real app probe additionally matched the NSWorkspace foreground PID, AX PID, and resolved SCK PID on the main display.
- The final gates pass: 131 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 5 targeted resolver tests, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, forbidden-API scan, and whitespace validation. Evidence: `Results/LM-020/report.json` and `Results/LM-020/resolver.json`.

## 2026-08-28 — LM-021 passed

- Five explicit adapter definitions cover Safari, Chrome, Arc/Dia-family Chromium, Edge, and Firefox through exact bundle-identifier allowlists and public Accessibility address/document attributes. The production path has no DOM, WebKit, browser-history database, network-traffic, or private-API access.
- Browser context is accepted only after the already-resolved SCK target PID matches the observed AX window PID and normalized bounds. Duplicate candidate address fields, bundle lookalikes, PID/bounds mismatches, unsupported schemes or ports, missing URLs, and unknown private state all return typed unavailable results.
- URL normalization accepts only HTTP/HTTPS with a default port, lowercases scheme and host, retains only a validated absolute path, and constructs serialization from sanitized components. It never reuses the source URL string, so credentials, query, and fragment components cannot cross the serialization boundary.
- Private classification is content-free: it contains only the browser family, resolved target-window ID, and private flag. The system inspector returns before reading address fields for private or uncertain windows, and no private title or URL is exposed by the output.
- The signed 600-context matrix achieves 1.0 exact accuracy: 480 approved sanitized contexts, 30 content-free private classifications, and 90 typed unavailable cases. The final gates pass: 138 XCTest unit tests plus 9 Swift Testing tests, 7 integration tests, 4 privacy tests, 1 performance test, 7 targeted browser tests, 11 contracts, privacy smoke, universal offline-capable Release build, signing posture, release-binary audit, forbidden-source scan, and whitespace validation. Evidence: `Results/LM-021/report.json` and `Results/LM-021/browser-context.json`.
