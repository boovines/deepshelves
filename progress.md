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
