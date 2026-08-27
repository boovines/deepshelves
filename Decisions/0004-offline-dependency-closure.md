# ADR 0004: Cache-only builds and deny-all shipping runtime

- Status: Accepted
- Date: 2026-08-28
- Story: LM-008
- Spike: S7

## Context

DeepShelves must install and reach visual search on a fresh offline Mac, and every shipping journey must make zero network attempts. Build tooling may use only the pinned dependency cache during the documented bootstrap step. Wrapping Xcode's build itself in `sandbox-exec` is not a valid proof on this macOS version because SwiftPM applies its own child sandbox and nested `sandbox_apply` fails with `Operation not permitted` before compilation.

## Decision

Materialize GRDB 7.11.1 and SQLCipher 4.18.0 only from the byte-verified local cache, disable automatic package resolution for release builds, and bundle the manifest-verified MobileCLIP resources. Treat build closure and runtime closure as separate fail-closed proofs:

- the build uses only verified cache inputs with automatic resolution disabled;
- the signed app, CLI, and MCP journey runs under `sandbox-exec` with `deny network*`;
- linked frameworks, network symbols, source literals, telemetry, upload, remote-resource, and updater components are audited independently;
- each regular shipping file records source, version, license, SHA-256, and update procedure.

No runtime downloader, updater, remote model, font, favicon, telemetry, or crash-upload component is permitted. A newly installed archive is owner-only before onboarding or capture begins.

## Consequences

- First launch, onboarding, local capture ingestion, text and visual search, deletion, export, CLI, and MCP remain usable without a network.
- MobileCLIP becomes a shipping dependency for this private research build; its existing research-only license limitation remains binding.
- Dependency updates require a reviewed manifest change, cache refresh, hash verification, and a complete S7 rerun.
- The inactive GRDB diagnostic URL literal remains classified as inert error text; it is not a network path and no networking symbol or framework is linked.

## Verification

`scripts/check-s7-offline-spike.sh` requires a successful fresh offline visual-search journey, a positive network-denial instrumentation control, zero shipping DNS/TCP/UDP/HTTP/QUIC attempts, complete per-file provenance, cache-only build evidence, and zero forbidden linked or source components. The canonical run is linked from `Results/LM-008/report.json`.
