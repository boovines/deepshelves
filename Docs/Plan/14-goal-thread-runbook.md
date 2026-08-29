# Resumable Goal-Thread Runbook

## Purpose

This runbook lets one long-running Codex goal—or a replacement thread after interruption—execute the backlog without relying on conversation memory. The repository and its evidence files are the source of truth.

The goal is not “write the whole app in one turn.” It is:

> Repeatedly complete the next unblocked LM story, verify it, checkpoint it, and continue until a defined human-only gate or the final release gate.

## Preconditions

The fixed implementation workspace is `/Users/justinhou/Development/deepshelves`. LM-001 creates/initializes it, creates a private GitHub repository named `deepshelves` with that local repository as `origin`, and copies the planning set into `Docs/Plan/`; after that, the committed in-repository plan snapshot is canonical. The repository must never be made public as an authentication workaround. Before other work, the agent creates:

- `phase-state.json` from the schema in plan 13
- append-only `progress.md`
- `Decisions/`
- `Results/`

`HUMAN-ACTION.md` must be absent during normal execution and is created only for a `blocked_human` pause.

The goal thread begins by checking current branch/status, existing user changes, Xcode availability/license state, available disk, macOS/CPU architecture, and the next story. It never resets or overwrites unrelated user work.

## Durable execution loop

For each story:

1. Read master plan, active category plan, contracts, story row, applicable spike/ADR, `progress.md`, and `phase-state.json`.
2. Verify every dependency is `passed` and working tree ownership is understood. Before
   LM-064, ADR-0006 dependencies may instead be blocked/implementation-ready/H9-deferred;
   record that distinction explicitly. Never use this exception after LM-064.
3. Set exactly one story to `active`; record start time and base revision.
4. Add the fixture/test that demonstrates the story outcome.
5. Implement only that story, including user-visible failure/recovery behavior.
6. Run only focused changed-behavior tests, strict formatting for changed files, a targeted
   static privacy/safety check, and one cached native arm64 compile when needed. Run a broad
   gate here only if the story directly changes that surface.
7. Fix failures while they remain within the story and fixed architecture.
8. Write concise evidence under `Results/<story-id>/`: command/result/hash/final metrics and
   useful failure excerpts, not duplicate successful logs. Append durable lessons and
   update documentation when behavior changed.
9. Mark `passed` only when all acceptance evidence exists.
10. Create one atomic Git checkpoint whose message starts with the story ID, staging only files owned by that story and never unrelated user changes; push the verified checkpoint to the private `origin` before beginning the next story.
11. Re-read the next story and continue automatically.

After LM-048, LM-064, LM-071, and LM-085, run the ADR-0007 milestone checkpoint: one
universal Release build and the applicable broad privacy, dependency, contract, benchmark,
and repository suites. Run the complete final release gate again at LM-086. Reuse
DerivedData and resolved dependencies, suppress successful build output, and do not perform
redundant clean builds. After two repetitions of the same failure, diagnose once and change
approach rather than rerunning an unchanged command.

LM-039–LM-046 form one Recall UI implementation stream and remain technically blocked
until H9. LM-075–LM-079 are `adr_removed` by ADR 0007 and are skipped without being called
implemented or passed. LM-080 depends on LM-074 for the personal alpha.

### Prohibited runtime on the owner's laptop

The owner does not authorize application, ScreenCaptureKit, ImageIO, VideoToolbox, or
hardware-media runtime testing on this laptop. Do not launch them through a test, probe,
helper, profiler, UI automation, screenshot path, or indirect framework call. Unit, model,
static, compile, and deterministic offscreen snapshot checks are allowed only after source
inspection proves they cannot reach a prohibited runtime. Reports must name these proof
classes honestly and list the original runtime acceptance separately.

ADR 0006 moves all such deferred checks into one H9 ledger at LM-064 on an isolated
validation Mac. A story remains `blocked`; `implementationReadiness: ready` merely allows
safe downstream implementation. If a story cannot be implemented further without one of
the prohibited runtimes, record the exact boundary and stop it rather than guessing.

If the process/thread is interrupted, the next run validates the last `passed` checkpoint and resumes the sole `active` story. It never trusts status without rerunning the recorded validation command.

## Human-only pause protocol

When macOS or account state requires the user:

1. Bring the system to a safe stopped state; canonical capture must be off.
2. Set the active story to `blocked_human`.
3. Write `HUMAN-ACTION.md` containing exactly:
   - blocking story and reason
   - one concrete action for the user
   - what the user should expect to see
   - what must not be approved or changed
   - command/probe the agent will run afterward
4. Stop and ask the user to complete that action and reply `done` in the goal thread.
5. On resume, verify the capability rather than trusting the reply.
6. Delete `HUMAN-ACTION.md`, return the story to `active`, and continue.

The user may take arbitrarily long. All state needed to resume is on disk. A new thread can resume with: `Read 00-master-plan.md and 14-goal-thread-runbook.md, inspect phase-state.json and HUMAN-ACTION.md, verify the last checkpoint, and continue the next unblocked LM story.`

## Enumerated human gates

The agent may not invent additional approval gates merely because work is difficult. These are the expected ones:

| Gate | Trigger | User action | Agent verification |
|---|---|---|---|
| H0 Xcode readiness | Full Xcode/components or license not ready | Open Xcode, install requested components, accept Apple's Xcode license | `xcodebuild -version` and a generated release build succeed |
| H1 Signing identity | Stable Apple Development/local signing identity or Keychain group requires account/UI | Select/create the intended local development team/signing identity; approve only the named Keychain prompt | `codesign` designated requirement/entitlements and signed-helper Keychain test pass |
| H2 Screen/Accessibility TCC | First real capture and AX test | In System Settings, grant Screen & System Audio Recording and Accessibility to the fixed app bundle | App capability probes return granted and foreground-window sentinel test passes |
| H3 Launch-at-login | SMAppService asks for user confirmation | Approve Local Memory under Login Items when prompted | Service status is enabled and relaunch test passes |
| H4 Optional audio TCC | A future accepted ADR restores LM-075–LM-079 and the user elects audio | Grant only the requested microphone/system-audio permission | Audio capability probe and local fixture capture pass |
| H5 Three-workday dogfood | LM-081 | Use the app during three normal workdays; record observed failures/false exclusions/UX friction in the supplied form. The days need not be consecutive. | Agent ingests the report only after the user manually resumes, checks bounded local diagnostics, and reproduces or dispositions every item. |
| H6 Fresh-install rehearsal | LM-083 | Follow the supplied install/permission/revoke/uninstall checklist on the target Mac | Agent reruns probes and records resulting state/evidence |
| H7 Final subjective review | LM-085 | Review the deterministic UI gallery and five core journeys; list unacceptable issues or explicitly accept | Agent fixes listed blockers and records user acceptance; numeric/accessibility gates still run automatically |
| H8 GitHub authentication | LM-001 cannot create/push the private `deepshelves` remote | Authenticate GitHub CLI for the intended account and confirm private visibility; do not authorize public creation | `gh auth status`, `git remote -v`, and repository visibility inspection pass; initial plan/build checkpoint pushes successfully |
| H9 Isolated runtime validation | LM-064 after all safe implementation work through LM-063 is ready | Provide a physically distinct, recoverable validation Mac with the pinned revision/toolchain and grant only the documented Screen Recording/Accessibility permissions there | Run the ordered ADR-0006 ledger once; every LM-028/LM-039 and later deferred runtime check has real evidence, no prohibited service escapes the tripwire, and affected stories are promoted in dependency order before LM-064 passes |

A paid Apple Developer Program membership and App Store submission are not required. Apple-account authentication, TCC consent, Keychain prompts, microphone consent, real-world dogfood, and subjective visual approval cannot be assumed automatable.

### H5 credit-silent observation protocol

H5 is an offline human observation window, not an agent-monitoring task. Before the first
dogfood day, the agent must checkpoint LM-080, set LM-081 to `blocked_human`, write the
observation form and exact resume probe to `HUMAN-ACTION.md`, and end its active turn. It
must not create or leave running a Codex automation, scheduled task, heartbeat, sub-agent,
polling loop, terminal watcher, or recurring status check. The Local Memory app may write
only the bounded local diagnostics already required by LM-080.

The user runs the app normally for three workdays and manually returns to the goal thread
afterward. Codex usage during the observation window must be zero because no Codex task is
active. On manual resume, the agent reads the supplied form and local diagnostics once,
deletes `HUMAN-ACTION.md` after verifying the gate, and continues LM-081.

## Decisions the agent can make without pausing

The agent may:

- implement and debug within fixed package/contract boundaries
- tune a numeric constant through the exact sequence in plan 12
- choose an internal algorithm that does not change public behavior, privacy, evidence semantics, or performance gates
- add tests, fixtures, local diagnostics, and recovery behavior
- update dependencies to the pinned revision already selected by LM-004
- create atomic commits and restore its own incomplete file edit without touching unrelated user work

The agent must pause for:

- changing foreground-window-only capture or any privacy invariant
- adding network access, cloud inference, telemetry, or automatic downloads
- changing a contract in a way requiring data migration beyond the active story
- accepting lower privacy/deletion/integrity gates
- replacing the fixed native architecture/model/database
- destructive recovery of a real archive
- credentials, TCC, signing/account UI, or physical/user-observation gates above

## Blocked technical work

A technical failure that needs no user authority uses `blocked`, not `blocked_human`. Before stopping, the agent must exhaust the story's documented fallback sequence and record:

- minimal reproduction and raw output
- suspected layer and evidence
- attempted fixes
- whether fixed invariants remain satisfiable
- smallest decision required

Under ADR 0006, a story whose implementation is safely complete but whose runtime evidence
is prohibited here stays `blocked`, records `implementationReadiness: ready` and H9, and may
be consumed only as a pre-LM-064 implementation dependency. It is never reported complete.

The next thread can then continue from evidence rather than restarting diagnosis.

## Recommended initial goal prompt

    Build Local Memory by following
    /Users/justinhou/Development/coast-dup-plan/00-master-plan.md,
    /Users/justinhou/Development/coast-dup-plan/13-implementation-backlog.md, and
    /Users/justinhou/Development/coast-dup-plan/14-goal-thread-runbook.md. Work one LM story at a
    time, verify and checkpoint each story, continue automatically while an unblocked
    story remains, and never weaken a fixed privacy/architecture decision. When an
    enumerated human-only action is required, write HUMAN-ACTION.md, set blocked_human,
    stop safely, and ask me for that one action. After I reply done, verify it and resume.
    Create and perform all implementation work in /Users/justinhou/Development/deepshelves;
    do not modify /Users/justinhou/Development/trace-recorder.

If the planning directory later moves into the implementation repository, update these three absolute paths before starting the goal.

## Completion condition

The goal is complete only when LM-086 is `passed`, every evidence link resolves, no
`active`/`blocked`/`blocked_human` story remains, every `adr_removed` story names its
accepted disposition without an implementation claim, the release build passes offline,
and the final tag/checkpoint points to the exact verified revision.
