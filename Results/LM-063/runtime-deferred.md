# LM-063 runtime evidence deferred to H9

The isolated-host runtime runner is implementation-ready but was not executed on this
laptop. `scripts/run-lm063-offline-gate.sh` requires explicit
`DEEPSHELVES_H9_ISOLATED_VALIDATION=1` authorization and refuses the owner's physical Mac by
comparing a one-way hardware-identity hash.

H9 must run the script on the physically distinct validation Mac. It performs the cache-only
Release build, positive instrumentation control, application/CLI/MCP journeys under deny-all
outbound policy, unified sandbox denial inspection, DNS/socket symbol inspection, linked
framework and component audit, model/resource checksum verification, and complete per-file
provenance. Only a passing run may create `Results/LM-063/offline.json`.

The local `offline-static.json` proves only source, dependency-cache, and model-manifest
closure. It has `runtimeExecuted: false` and is not a substitute for the missing runtime
audit.
