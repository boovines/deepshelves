# ADR 0006: Deferred isolated-Mac runtime validation

- Status: Accepted
- Date: 2026-08-29
- Stories: LM-028, LM-039, LM-040–LM-048, LM-056–LM-064
- Human gate: H9

## Context

DeepShelves has two implemented stories whose remaining acceptance evidence cannot be
collected safely on the owner's laptop:

- LM-028 still requires the real eight-hour foreground-window production soak. A hardware
  HEVC probe caused two repeatable `dart-ave AppleT8110DART` kernel panics, Apple ImageIO
  unexpectedly started `VTEncoderXPCService`, and a later headless ScreenCaptureKit smoke
  also left that service running despite use of the pinned software HEIC writer.
- LM-039 still requires its warm, slow, and error XCUITest fixtures. Application launch on
  this laptop is quarantined because it can enter the same unsafe media-service environment.

The owner does not authorize application, ScreenCaptureKit, ImageIO, VideoToolbox, or
hardware-media runtime testing on this laptop. Unit, model, pure-software helper, static,
compile, and deterministic snapshot verification remain authorized when source inspection
proves they cannot enter a prohibited runtime.

Keeping every downstream dependency frozen would prevent implementation work that can be
proved independently of those runtime checks. Marking either story passed would falsely
waive acceptance criteria. The execution model therefore needs separate implementation and
release-evidence readiness without changing product behavior or privacy gates.

## Decision

Keep LM-028 and LM-039 in technical `blocked` status. Record each as
`implementationReadiness: ready` with `deferredValidationGate: H9` only after all nonruntime
acceptance work, safe tests, failure behavior, and evidence for that story are complete.

An implementation dependency is eligible when its upstream story is either:

1. `passed`; or
2. `blocked`, explicitly `implementationReadiness: ready`, assigned to H9, and blocked only
   on evidence that requires a prohibited runtime.

This eligibility permits source implementation and safe verification only. It does not make
the upstream story complete, satisfy its acceptance criteria, authorize release, or allow a
downstream story to claim runtime behavior based on unit/model/static/compile/snapshot proof.
Every downstream story that reaches its own runtime-only evidence boundary remains
`blocked`, records its safe evidence separately, and joins the same H9 ledger.

H9 runs once at LM-064 on an isolated validation Mac. That Mac must be physically distinct
from this laptop, expendable or recoverable, compatible with the pinned toolchain, and have
the required Screen Recording and Accessibility consent. H9 executes the accumulated
runtime ledger in dependency order, including at minimum:

1. LM-028's real eight-hour foreground-window production soak and contamination/resource
   scans with the pinned software HEIC helper and encoder-service tripwire;
2. LM-039's warm/slow/error XCUITest fixtures;
3. every later UI journey, accessibility interaction, live offline, or application-runtime
   acceptance check explicitly registered in the ledger before LM-064.

If VideoToolbox or any hardware-media service appears unexpectedly, the H9 run stops,
preserves content-free diagnostics, and leaves every affected story blocked. H9 may not
reinterpret a snapshot, model, compile, or fake test as runtime evidence. After every ledger
entry passes, each deferred story receives its real evidence, is promoted to `passed` in its
own dependency order, and LM-064 may complete. No story after LM-064 may use implementation
readiness in place of a passed dependency.

## Invariant analysis

| Invariant | Effect of deferral |
|---|---|
| Foreground-window isolation | Unchanged. Fakes and models exercise the same target/epoch/policy admission contract; H9 still must prove the real single-window surface. |
| Local-only operation | Unchanged. Safe work and H9 use deny-all runtime networking and owner-only evidence. |
| Privacy identity | Unchanged. No blocked story is promoted without real target/epoch/locator evidence where required. |
| Atomic publication and integrity | Unchanged. Fault/model tests continue locally; H9 supplies the missing production-runtime evidence. |
| Search evidence | Unchanged. Snapshots cannot substitute for exact live-source evidence. |
| Retention and forensic deletion | Unchanged. Downstream implementation can use deterministic archives, but release remains blocked until H9 completes the real runtime ledger. |
| Accessibility and UX | Compile/snapshot/model evidence guides implementation; actual keyboard, VoiceOver, timing, and journey checks remain mandatory H9 entries. |

## Consequences

- The repository can continue dependency-safe implementation without exposing this laptop
  to prohibited runtime paths.
- `blocked` continues to mean acceptance is unsatisfied; `implementationReadiness` is a
  narrow scheduling property, not a completion status.
- More stories may accumulate in the H9 ledger. This reduces repeated machine setup but
  increases the size of the final validation batch and the risk of late runtime defects.
- Safe verification must name its proof class. Reports use `unit`, `model`, `static`,
  `compile`, or `snapshot`; none may be labeled integration/runtime when the app did not run.
- LM-086 remains impossible until H9 has passed, every deferred story is `passed`, and no
  `blocked` story remains.

## Alternatives considered

- **Mark LM-028/LM-039 passed from safe evidence:** rejected because it waives explicit
  acceptance criteria and misrepresents evidence.
- **Stop all implementation now:** safe but unnecessary; downstream pure logic, storage,
  projection, and UI composition have deterministic seams.
- **Run another narrow probe on this laptop:** rejected by owner prohibition and repeated
  encoder-service evidence.
- **Create separate runtime gates per story:** rejected because it repeatedly exposes and
  configures a validation host; one ordered ledger is easier to stop, audit, and reproduce.

## Verification

Before each downstream story begins, the executor records which upstream dependencies are
`passed` and which are H9 implementation-ready. Its story report lists every safe proof and
every deferred runtime check separately. Static process and source audits must show that no
application, ScreenCaptureKit, ImageIO, VideoToolbox, or hardware-media runtime was invoked
on this laptop.

At H9, `Results/LM-064/isolated-validation-ledger.json` binds the isolated host declaration,
exact git revision, commands, story/evidence mapping, process tripwire output, and pass/fail
result for every deferred check. A missing or failed ledger item leaves its story blocked.

## Revisit triggers

Revisit only if the owner changes the laptop prohibition, an isolated validation Mac is
available, or a new runtime-only requirement cannot be represented as an H9 ledger entry
without changing product/privacy architecture.
