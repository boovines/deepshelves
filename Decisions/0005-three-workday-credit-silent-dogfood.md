# ADR 0005: Three-workday credit-silent personal dogfood gate

- Status: Accepted
- Date: 2026-08-28
- Story: LM-081

## Context

The original release plan required five normal workdays of personal dogfood. Real use is
still necessary for an always-running foreground-window recorder because accelerated tests
cannot fully reproduce ordinary sleep/wake cycles, application switching, permission drift,
resource discomfort, false exclusions, or cumulative usability friction. However, five
workdays creates unnecessary calendar delay for this personal-use MVP. Leaving Codex active
to monitor that delay would also consume credits without improving the observation.

## Decision

Shorten the LM-081 personal dogfood gate from five to three normal workdays. The days need
not be consecutive. Preserve the same evidence categories: search failures, false
exclusions, privacy/deletion blockers, resource discomfort, crashes, UX friction, bounded
local diagnostics, and disposition of every reported issue.

Make the observation interval explicitly credit-silent. Before it starts, Codex checkpoints
LM-080, completes the H9 isolated-Mac runtime gate under ADR 0006, records the H5 instructions
and resume probe, sets LM-081 to `blocked_human`, and ends its active turn. No Codex
automation, scheduled task, heartbeat, sub-agent, polling
loop, terminal watcher, or recurring status check may run during the three workdays. The
user manually resumes the goal after completing the observation form.

## Consequences

- Release confidence still includes multiple independent real-use days and repeated
  sleep/wake and launch cycles.
- The calendar gate is reduced by 40 percent.
- Codex consumes no credits during the observation interval.
- The existing LM-082 72-hour accelerated fault soak remains unchanged and continues to
  cover mechanical long-duration, clock-advance, and disk-pressure behavior.
- A privacy, deletion, corruption, or disruptive-resource failure still blocks release;
  shortening the window does not weaken those acceptance thresholds.

## Verification

LM-081 evidence must include a three-workday observation report, LM-080 bounded local
diagnostics covering those sessions, resource percentiles, issue dispositions, and a record
that the goal was manually resumed after an inactive H5 pause. The runbook and completion
gates must contain no remaining five-day requirement.
