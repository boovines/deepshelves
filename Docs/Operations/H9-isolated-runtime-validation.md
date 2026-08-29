# H9 isolated runtime validation

This is the single ordered runtime session required by ADR 0006 after LM-080 and before
LM-081. It runs only on a physically distinct, recoverable validation Mac. Nothing in this
document authorizes application or media runtime on the owner's laptop.

## Host admission

Before any product process starts, record the exact checkout revision, `sw_vers`, hardware
model/identity hash, Xcode/Swift versions, dependency-lock hashes, signing identity, free
space, and TCC state. The host must not match the owner's stored hardware-identity hash.
Confirm no `xcodebuild`, `xctest`, `VTEncoderXPCService`, or other hardware-media process is
running. Configure deny-all outbound instrumentation and the 50 ms encoder-service
tripwire. Grant only Screen Recording and Accessibility to the fixed signed bundle.

If VideoToolbox or another hardware-media service appears, stop the active process and the
entire session immediately, preserve content-free diagnostics, set the item failed, and do
not continue or retry unchanged. The two historical `dart-ave AppleT8110DART` panics must
never be reproduced.

## Ordered execution

Copy `Results/H9/isolated-validation-ledger.template.json` to
`Results/H9/isolated-validation-ledger.json`, bind it to the exact validation revision and
host, then execute H9-001 through H9-020 without reordering. Each item must record its exact
command/journey, tripwire result, pass/fail disposition, and content-free artifact paths.
The detailed unchanged checks are in each source story's `runtime-deferred.md`, report, or
blocker. H9-012 additionally produces `Results/LM-063/offline.json`.

The session fails closed on a missing, failed, skipped, reordered, host-mismatched, or
revision-mismatched item. Safe unit/model/static/compile/snapshot evidence cannot populate a
runtime result. Captured owner-only evidence stays outside Git; the ledger records only
content-free hashes, metrics, transcripts, and paths.

## Promotion and exit

Only after all 20 items pass, promote their source stories from blocked to passed in the
same dependency order, attach their runtime evidence, mark H9 passed, and checkpoint/push
the exact validated revision and ledger. Verify there is no active product, build, test,
tripwire, watcher, or media process before leaving the validation host. LM-081 may not begin
until this promotion checkpoint exists.
