# Product Fidelity and Scope

## Outcome

Build a single-user macOS application that provides the capabilities Coast Local publicly describes today: ambient screen memory, local enrichment, fast recall, a visual timeline, activity summaries, privacy controls, and scoped access for local agents.

This plan targets functional equivalence, not copied branding, assets, wording, or pixel-identical UI.

## Product definition

The product is a private memory layer for one Mac:

1. It runs quietly from the menu bar.
2. It observes meaningful changes in on-screen activity.
3. It captures a visual keyframe and available structured context.
4. It enriches the capture locally.
5. It makes history searchable by content, application, website, and time.
6. It lets the user inspect and scrub surrounding moments.
7. It exposes narrowly scoped history to local agents.

The core user promise is: “Find something I previously saw or did without sending my workday to a cloud service.”

V1 captures only the uniquely resolved, policy-approved foreground window. It does not persist the composited desktop or background windows. Menus, notifications, Dock/menu bar, and unrelated adjacent windows may therefore be absent; this is an intentional privacy trade-off, not a missing implementation.

## Evidence-based Coast fidelity matrix

| Capability | Evidence | Required here |
|---|---|---|
| Always-on background capture | Coast landing page, FAQ, terms, launch video | Yes |
| Periodic rather than lossless capture | Coast terms | Yes |
| Local screenshots and extracted text | Coast privacy notice and FAQ | Yes |
| OCR and Accessibility enrichment | Coast privacy notice | Yes |
| Search by text, app, site, and time | Coast launch video and product UI | Yes |
| Screenshot result grid | Coast launch video | Yes |
| Exact timestamp and visual timeline | Coast launch video | Yes |
| Pause, app/site exclusions, private-window exclusion | Coast FAQ | Yes |
| Retention and storage limits | Coast FAQ | Yes |
| Activity heatmap and app totals | Coast frontend demonstration | Yes |
| Agent access through a CLI | Coast getting-started page | Yes, through CLI and MCP |
| Optional local audio transcription | August 2026 privacy notice | Optional final phase |
| Account, sync, collaboration, billing | Not needed for personal use | No |
| Workflow learning or autonomous replay | Company vision, not demonstrated Coast Local behavior | No |
| Telemetry, crash upload, favicon services | Coast uses them, but they weaken local-only assurance | No |

## Primary journeys

### Recall by description

The user presses a global shortcut, types “lamp today,” sees screenshot cards, filters to Chrome, opens one result, and scrubs nearby moments.

### Recall by time

The user opens Today, sees an hourly timeline, jumps to 2:30 PM, and reviews the surrounding sequence of application changes.

### Activity review

The user opens Activity and sees time by application, an hourly/day heatmap, active versus idle time, and capture gaps.

### Privacy control

The user pauses recording, excludes a password manager and specific domains, deletes the last 15 minutes, and verifies that those moments no longer appear.

### Agent context

A local MCP client asks for activity during a bounded time range. The app returns text summaries and metadata by default; screenshots require a separate explicit capability.

## Scope boundaries

### Required

- Apple Silicon Mac, macOS 15 or later
- One local user and one local data store
- Main display only in V1; multi-display capture requires a later contract/performance ADR
- Foreground-window-only pixels; full-display capture is explicitly outside V1
- Background capture with visible menu-bar state
- Accessibility-first extraction with OCR fallback
- Hybrid lexical and visual-semantic retrieval
- Screenshot grid, result detail, timeline, filters, and activity analytics
- Local CLI and MCP interface
- No default outbound network access
- Deletion, exclusion, and retention controls

### Explicit non-goals

- Cross-platform support
- Cloud sync or backup
- Accounts, teams, billing, or telemetry
- Remote access
- Hidden recording
- Compliance archiving
- Keystroke logging
- General-purpose workflow automation
- Exact reproduction of Coast’s UI or proprietary behavior

## Product principles

1. Capture less, but capture meaningfully.
2. Prefer structured Accessibility content; use OCR as a fallback and visual embeddings as a complement.
3. Search must degrade gracefully: exact text before semantic inference.
4. Recording state must always be legible.
5. Exclusion happens before pixels or text are persisted.
6. Deletion must remove media, indexes, derived data, and cached previews.
7. Agent access is narrower than human access by default.
8. Every model and dependency must run locally after installation.

## Success metrics

Create the synthetic/licensed benchmark specified in plan 10: at least 500 known moments and 100 representative queries. Personal dogfood results are evaluated separately and never committed as fixtures.

- Recall@5 at least 0.90 for exact or near-exact text queries
- Recall@10 at least 0.80 for visual or semantic queries
- Lexical/filter search p95 below 300 ms
- Hybrid search p95 below 750 ms at one million indexed frames
- Result detail opens at p95 below 200 ms after thumbnail selection
- At least 95% of meaningful app switches represented by a keyframe
- No excluded application or domain content persisted in privacy tests
- No outbound connection attempts during normal use, first launch, inference, or helper access
- Capture gap after wake or crash no longer than 60 seconds
- Average CPU below 6% during normal knowledge-work use
- Storage target below 20 GB per month at default settings

## Delivery slices

1. Text recall: capture, Accessibility/OCR, local storage, FTS search.
2. Visual history: thumbnails, exact timestamps, timeline and scrubbing.
3. Semantic recall: image/text embeddings and hybrid ranking.
4. Trust controls: exclusions, deletion, retention, offline proof.
5. Agent memory: read-only CLI and MCP.
6. Activity and optional audio.

## Acceptance gate

This document is complete when every publicly demonstrated current Coast Local capability is either mapped to a build phase or explicitly excluded with a rationale. Future Attention automation claims must not silently enter scope.

## Sources

- [Coast product page](https://coast.app/)
- [Coast getting started](https://coast.app/downloaded)
- [Coast FAQ](https://coast.app/faq)
- [Coast terms](https://coast.app/terms)
- [Coast launch video](https://x.com/aidangch/status/2082134857862578585)
- [Screenpipe reference implementation](https://github.com/screenpipe/screenpipe)
