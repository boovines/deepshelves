# ADR 0002: Signed application executable helper entry points

- Status: Accepted
- Date: 2026-08-28
- Story: LM-008
- Spike: S5

## Context

DeepShelves needs one random 256-bit SQLCipher key to be readable by the app, CLI, and MCP modes while remaining inaccessible to unsigned or differently entitled code. The S5 release-mode spike verified the Keychain ACL with the real Apple Development signature. It also exercised an independently compiled unsigned probe and a signed process using a deliberately mismatched access group.

The original shared-access-group design could not be proven for separate development-signed helper products without adding provisioning and ACL uncertainty. Plan 12 explicitly authorizes embedding the CLI and MCP modes in the signed application executable when shared helper access fails signing/access tests.

## Decision

Ship CLI and MCP behavior as explicit `--cli` and `--mcp` entry points of the signed application executable. Keep a single Keychain item whose access group is fixed by the app's signed entitlements. Never broaden the ACL, use an access-control prompt loop, copy the key into files or environment variables, or permit unsigned helper access.

The standalone target stubs are networkless, unprivileged launch surfaces and carry no Keychain access group. They remain unable to read encrypted content until their later stories route requests into the signed application entry points. The S5 harness labels the three privileged invocations app, CLI, and MCP but executes all through the same verified signed binary.

## Consequences

- All three modes read identical 32-byte key material without serializing it.
- Unsigned and mismatched-access-group probes fail with `errSecMissingEntitlement` (`-34018`).
- Helper installation cannot create an independently updateable or differently signed code path to encrypted content.
- Standalone launcher scaffolds start successfully but have no Keychain entitlement and therefore no direct archive access.
- Later CLI/MCP stories must preserve read-only, scoped access and cannot weaken this signing boundary.

## Verification

`scripts/check-s5-storage-spike.sh` requires successful app/CLI/MCP key hashes, denied unsigned and mismatched probes, absence of key material in evidence, and a signed Release environment declaration. The canonical S5 report is linked from `Results/LM-008/report.json`.
