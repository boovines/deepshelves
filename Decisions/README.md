# Architecture decision records

Numbered ADRs document any measured fallback or approved change to a fixed architecture, contract, privacy boundary, or model.

ADR 0006 separates implementation dependency readiness from release acceptance for runtime
checks that are prohibited on the owner's laptop. It never changes a story's `blocked`
status or treats safe proof classes as substitutes for deferred runtime evidence.
