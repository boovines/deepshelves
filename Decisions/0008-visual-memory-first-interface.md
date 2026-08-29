# ADR 0008: Visual-memory-first product interface

- Status: Accepted
- Date: 2026-08-29
- Stories: LM-040–LM-048, with setting-surface convergence in LM-048
- Runtime gate: H9 remains mandatory
- Supersedes: the permanent three-pane main-window composition in plans 00, 06, and 11

## Context

The implementation through LM-080 proves the product's capture, storage, search, deletion,
agent-policy, activity, and diagnostic contracts, but its main interface reads like a
database browser. The selected reference screenshots demonstrate a more legible product
hierarchy: one dominant visual memory, compact window actions, spatial previous/next and
scrubbing controls, a persistent timeline rail, a prominent search/agent composer, and a
settings window organized around a stable sidebar and spacious grouped surfaces.

The references are evidence for composition, density, hierarchy, interaction
discoverability, and finish. Their product name, logo, artwork, icons, exact wording, source
code, and other proprietary assets are not implementation inputs. Local Memory continues
to capture only the approved foreground window; it must never imply that a whole desktop,
background window, notification, Dock, or menu-bar surface was stored.

Application, ScreenCaptureKit, Apple ImageIO, VideoToolbox, AVAssetWriter, XCUITest, and
media runtime remain prohibited on the owner's laptop under ADR 0006. The visual redesign
therefore needs an implementation path that can be proved safely without mislabeling that
proof as runtime acceptance.

## Decision

### Product composition

Local Memory's primary Timeline is a visual-memory surface:

- a restrained title bar contains compact Search and Settings actions;
- a single aspect-fit screenshot canvas dominates the window;
- previous and next moment controls flank the canvas and have keyboard equivalents;
- the selected local date and time sits at the canvas's lower leading edge;
- a persistent bottom rail shows application-colored intervals, recognizable application
  symbols, typed patterned gaps, a draggable playhead, and real zoom controls;
- provenance, evidence, Revisit, Export, and Forget move into a secondary disclosure that
  never obscures capture/privacy truth.

Search uses one large composer with two explicit routes: `Search Memory` and `Ask Agent`.
Both reuse the root-owned `SearchSessionModel`; no second search owner is introduced. Time,
website, and application filters remain visible and removable. Agent submission is exposed
only when it can create a bounded, expiring CLI/MCP policy and a supported target is
actually detected. The UI never claims a client is installed from a fixture or guess.

Settings uses a 240–280 point leading sidebar with General, Agents, Appearance, Capture,
Storage, and Exclusions. It uses large headers and 18–22 point grouped cards while retaining
Local Memory's actual services and states. Fresh profiles use Light appearance. System
appearance follows `NSAppearance` dynamically, and Dark uses semantic dark surfaces rather
than inversion. Capture quality choices are omitted until real validated capture parameters
exist. Visual-media encryption copy remains exact: database text is app-encrypted; visual
media relies on owner-only filesystem permissions and FileVault when enabled.

All product spacing remains on the 4-point grid. Native SwiftUI/AppKit, SF Symbols, SF Pro,
semantic system colors, one restrained azure accent, visible keyboard focus, VoiceOver,
Increased Contrast, Reduce Motion, and pseudo-localization remain mandatory. Every visible
control has a real action or is omitted.

### State and package boundaries

The root composition continues to own navigation, lifecycle, archive security, search, and
agent-policy services. Feature views receive narrow values, bindings, and actions. UI-only
fixture models may project deterministic states but may not duplicate `SearchEngine`,
`SearchSessionModel`, policy stores, deletion state, or capture lifecycle ownership.

`MemoryDesignSystem` owns the semantic palette, spacing, shape, typography, focus, card,
composer, timeline, settings-row, and snapshot-scenario primitives. Raw visual constants do
not spread through application feature files.

### Story and evidence treatment

LM-039 remains technically blocked and implementation-ready because its single-root search
binding is unchanged. LM-044 remains passed because its domain timeline contract is
unchanged. LM-040–LM-043 and LM-045–LM-048 are reopened for redesigned safe implementation.
Their earlier checkpoints and evidence remain immutable historical evidence; they are not
deleted or called invalid. Each story becomes implementation-ready again only after its new
focused unit/model tests, changed-file strict formatting, static privacy/safety audit,
cached native arm64 compile, deterministic offscreen snapshots, keyboard model, and
accessibility model evidence pass.

The required deterministic matrix covers default and minimum geometry for:

- Timeline: populated, empty, gap, corrupt frame, and loading;
- Search: initial, filtered, results, no results, adding visual matches, and error;
- Agent composer: unavailable, ready, and permission denied;
- every Settings section;
- Light, Dark, System semantic resolution, Increased Contrast, and pseudo-localization.

Offscreen snapshots use synthetic raster fixtures only and must be source-inspected before
execution to prove they cannot initialize the application, ScreenCaptureKit, Apple ImageIO,
VideoToolbox, AVAssetWriter, or any media codec runtime. They are `snapshot` evidence, not
installed-app screenshots.

H9 remains the only runtime gate. Its UI items are amended to validate the redesigned
composition, keyboard/VoiceOver interaction, real media presentation, drag scrubbing,
window resizing, appearance resolution, agent detection/routing, and destructive flows on
the known-safe validation Mac. No original acceptance criterion is waived or marked passed.
H9 now occurs after both the LM-080 checkpoint and this redesign's LM-048 safe checkpoint.

## Invariant analysis

| Invariant | Effect |
|---|---|
| Foreground-window privacy | Strengthened in UI copy and disclosure. The canvas represents one approved foreground window, never a desktop recording. |
| Local-only operation | Unchanged. No telemetry, remote update, favicon fetch, or cloud agent access is introduced. |
| Search evidence | Unchanged. The composer and visual layout reuse the existing hybrid engine and evidence provenance. |
| Agent access | Unchanged. `Ask Agent` can only create/use bounded CLI/MCP policies; unavailable or undetected targets are not advertised as installed. |
| Deletion and integrity | Unchanged. Forget remains provisional, fail-closed, and backed by verified physical rewrite. |
| Storage and encryption truth | Unchanged. Defaults remain 30 days/20 GB and the UI does not claim blanket visual-media encryption. |
| Runtime quarantine | Unchanged. Safe proof cannot populate H9 results. |

## Consequences

- The main experience becomes spatial and visual while advanced trust actions remain
  reachable through secondary disclosure and Settings.
- Existing functional implementation is reused instead of replaced with parallel state.
- The redesigned UI adds a new safe checkpoint after LM-080, so H9 and LM-081 move later
  without changing their acceptance criteria.
- Offscreen synthetic snapshots can catch composition and semantic regressions locally,
  but drag feel, real focus behavior, VoiceOver, installed client detection, media decode,
  and application window behavior remain unresolved until H9.

## Rejected alternatives

- **Copy the reference product exactly:** rejected for independence, product truth, and
  foreground-window privacy reasons.
- **Keep the three-pane database composition and only restyle it:** rejected because the
  hierarchy and interaction model, not merely colors, are the usability problem.
- **Build a second search or agent state owner for the composer:** rejected because it
  permits divergent results, filters, policies, and cancellation behavior.
- **Treat snapshots as runtime acceptance:** rejected by ADR 0006 and the original criteria.

## Verification

Each reopened story records its historical checkpoint, new safe evidence, and unchanged H9
ledger item. LM-048 includes a side-by-side review against the supplied references for
composition, hierarchy, density, spacing, discoverability, and polish, plus a list of every
intentional difference. The review must not score or reproduce proprietary branding.

