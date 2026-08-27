# DeepShelves / Local Memory

DeepShelves is a clean-room, local-only visual memory application for Apple Silicon Macs running macOS 15 or later. The product and architecture specification committed under `Docs/Plan/` is canonical.

## Bootstrap requirements

- Xcode 26.5 or later with the macOS SDK
- XcodeGen 2.46.0 (the expected version is recorded in `.xcodegen-version`)
- Apple Silicon and macOS 15 or later

Install the build generator once with `brew bundle`, then generate the project:

```bash
xcodegen generate --spec project.yml
```

All packages in the shipping graph remain local. LM-004 pins the future database, MCP, model/runtime, build, and test closure in `Dependencies/dependencies.json`; its explicit online-cache and offline-verification procedure is documented in `Dependencies/README.md`. No runtime target downloads a package or model.

## Verification

```bash
./scripts/privacy-smoke.sh
./scripts/check-dependencies.sh --static
./scripts/test.sh
./scripts/build-release.sh
```

The release script disables automatic package resolution and code signing for the deterministic bootstrap build. Signing and hardened-runtime posture are fixed in LM-002.

## Repository state

`phase-state.json` is the machine-readable execution checkpoint. `progress.md` is append-only. Story evidence is stored beneath `Results/<story-id>/`. `HUMAN-ACTION.md` exists only during an enumerated human gate.
