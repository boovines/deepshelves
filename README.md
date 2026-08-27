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

All source dependencies in LM-001 are local packages. After XcodeGen is installed, generation, tests, and builds run without network access.

## Verification

```bash
./scripts/privacy-smoke.sh
./scripts/test.sh
./scripts/build-release.sh
```

The release script disables automatic package resolution and code signing for the deterministic bootstrap build. Signing and hardened-runtime posture are fixed in LM-002.

## Repository state

`phase-state.json` is the machine-readable execution checkpoint. `progress.md` is append-only. Story evidence is stored beneath `Results/<story-id>/`. `HUMAN-ACTION.md` exists only during an enumerated human gate.

