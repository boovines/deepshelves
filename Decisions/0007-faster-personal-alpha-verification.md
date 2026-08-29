# ADR 0007: Milestone verification cadence for the personal alpha

- Status: Accepted
- Date: 2026-08-29
- Stories: LM-039–LM-086
- Supersedes: per-story broad-gate cadence in plans 00, 09, 13, and 14

## Context

DeepShelves is a personal-use alpha, not a separately audited release after every small
story. The original execution loop rebuilt both architectures and repeated repository-wide
privacy, dependency, contract, benchmark, and test suites after nearly every implementation
checkpoint. That cadence consumed substantial build time and Codex credit without changing
the evidence required at phase or release boundaries.

ADR 0006 separately quarantines application, ScreenCaptureKit, Apple ImageIO,
VideoToolbox, and hardware-media runtime on the owner's laptop. LM-039–LM-046 are safely
implemented but remain technically blocked until their unchanged runtime criteria pass at
H9 on the isolated validation Mac. Repeating safe broad suites between adjacent Recall UI
stories cannot supply that missing evidence.

Optional audio (LM-075–LM-079) is also unnecessary for the five core personal-alpha
journeys. Keeping it on the critical path delays a useful visual-memory product and adds a
new permission/model/media surface before the visual product is proven.

## Decision

### Per-story verification

Continue one LM implementation story at a time and keep its atomic commit/push checkpoint.
During a story run only:

1. focused tests for changed behavior;
2. strict formatting for changed source files;
3. a targeted static privacy/safety check for the affected boundary; and
4. one cached native arm64 compile when the changed surface needs compile integration.

Do not routinely run a universal Release build, repository-wide suite, full privacy audit,
full dependency audit, full contract suite, or unrelated benchmark. Run one only when the
active story directly changes that surface. Reuse DerivedData and resolved dependencies.
Suppress successful build output and retain a concise command/result/hash summary plus
only useful failure excerpts. After two repetitions of the same failure, diagnose once and
change approach instead of rerunning an unchanged command.

### Milestone checkpoints

Run the universal Release build and broad cross-cutting suites once at each remaining
milestone, then once more at the final release gate:

| Milestone | Stories | Broad checkpoint |
|---|---|---|
| Recall UI | LM-039–LM-048 | After LM-048 safe implementation is ready; runtime items remain in H9 |
| Trust/Lifecycle | LM-056–LM-064 | After LM-064 safe implementation is ready; runtime trust items remain in H9 |
| Agent Access | LM-065–LM-071 | After LM-071 adversarial policy suite |
| Pre-runtime Activity/Hardening | LM-072–LM-074 and LM-080 | After LM-080, immediately before H9 |
| Runtime/dogfood Hardening | LM-081–LM-085 | After LM-085, including the required H5/H6/H7 human gates |
| Final release | LM-086 | Exact release-candidate revision under the complete final gate |

The already-completed LM-049–LM-055 Visual Recall work needs no redundant new milestone
rerun. A story may still demand its own expensive gate when that gate is the story's stated
deliverable.

ADR 0008 later reopens LM-040–LM-043 and LM-045–LM-048 for a visual-memory-first redesign.
The same focused per-story cadence applies, followed by one refreshed Recall UI milestone
at LM-048. The earlier Recall milestone remains historical evidence and is not overwritten.
H9 moves after that refreshed safe checkpoint without adding another broad gate per story.

Treat LM-039–LM-046 as one Recall UI implementation stream. Preserve each story's
technical `blocked` status, `implementationReadiness: ready`, and H9 ledger entry. Continue
LM-047 and LM-048 using those safe dependencies. Unit/model/static/compile/snapshot proof
remains accurately labeled and never substitutes for deferred runtime evidence.

### Optional audio disposition

Remove LM-075–LM-079 from the personal-alpha critical path with phase-state status
`adr_removed`. This means “not implemented and intentionally deferred by ADR 0007,” not
passed, waived, or evidenced. Their backlog descriptions remain as a future option. LM-080
now depends on LM-074. H4 is dormant unless a future ADR restores audio work.

### Observation and runtime discipline

The complete ADR-0006 quarantine and H9 acceptance ledger remain unchanged. Under the
accepted ADR-0006 scheduling amendment, H9 runs after LM-080 and before LM-081. Foreground-
window isolation, exclusions, encryption, deletion/corruption correctness, fail-closed
behavior, bounded agent access, accessibility correctness, and all original acceptance
criteria remain mandatory.

No monitoring, polling, heartbeat, automation, terminal watcher, or agent activity may run
during human observation windows. At a human gate, checkpoint durable state and stop fully.

## Consequences

- Each remaining broad gate runs about five times rather than once per roughly 28 remaining
  critical-path stories: an estimated 82% reduction per broad gate category.
- Story feedback stays fast and specific, while milestone regressions are still caught
  before the next major dependency boundary.
- Failures may surface later than under per-story repository-wide testing; focused tests,
  static boundary checks, and milestone gates limit that risk.
- Routine evidence becomes smaller and more useful. Missing runtime evidence remains
  visibly missing rather than being buried in duplicate logs.
- The personal alpha reaches its five visual-memory journeys before optional audio work.

## Verification

Every story checkpoint records its focused commands and proof class. Every milestone report
records the exact revision, universal Release result, broad suite results, concise hashes or
metrics, failures if any, and all deferred H9 items. LM-086 verifies that milestone reports
resolve, every nonremoved story is passed, every `adr_removed` story names ADR 0007, and no
runtime criterion was represented as satisfied without its original evidence.

## Revisit triggers

Revisit if DeepShelves becomes a distributed product, multiple developers require CI on
every change, a milestone gate finds repeated cross-story regressions, or the owner elects
to restore optional audio after the personal alpha is usable.
