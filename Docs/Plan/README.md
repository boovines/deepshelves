# Local Screen Memory Planning Set

Start with [00-master-plan.md](00-master-plan.md), then use [13-implementation-backlog.md](13-implementation-backlog.md) as the execution queue.

The build is intentionally fixed as a clean-room native Swift macOS application. The category plans define product behavior and subsystem gates; [10-contracts-and-fixtures.md](10-contracts-and-fixtures.md) locks cross-package semantics, [11-ux-specification.md](11-ux-specification.md) removes interface guesswork, [12-baseline-spikes.md](12-baseline-spikes.md) supplies measured escape hatches, and [14-goal-thread-runbook.md](14-goal-thread-runbook.md) makes execution resumable across human-only pauses or replacement threads.

Suggested reading order for an implementation agent:

1. Master plan and global invariants
2. Current LM story and its category plan
3. Contracts/fixtures and UX specification when relevant
4. Baseline spike result or ADR on which the story depends
5. Existing `progress.md`, `phase-state.json`, and any `HUMAN-ACTION.md`

No Screenpipe or Coast source, assets, wording, or proprietary design should be copied. Public products and open projects are behavioral and performance references only.
