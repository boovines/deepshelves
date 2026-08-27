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

