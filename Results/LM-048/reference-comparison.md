# LM-048 independent reference comparison

Status: deterministic design review. This is not installed-app or H9 runtime evidence.

The attached material was treated only as visual evidence. Local Memory does not use Coast's name, logo, proprietary imagery, source code, app marks, distinctive copy, or whole-desktop capture model. Reference 8 is a brand icon and was intentionally excluded from the product composition; Local Memory keeps its independent identity.

| Reference | Composition and hierarchy learned from | Local Memory result | Intentional difference |
| --- | --- | --- | --- |
| 1 — Timeline | One dominant visual canvas, quiet chrome, spatial previous/next affordances, timestamp anchored near the canvas, and a persistent activity rail | Timeline is now the fresh-profile root. The selected exact-source moment dominates the window; compact Search and Settings actions stay in the top bar; a lower rail shows app-colored intervals, symbols, a playhead, and real zoom actions. | Local Memory displays only the accepted foreground window and explicit privacy gaps. It never reconstructs or implies the whole desktop. Provenance, Revisit, and Forget remain secondary disclosures. |
| 2 — General Settings | Stable left navigation, large section header, broad rounded cards, and low-density rows | Settings uses a 260-point sidebar, a large content title, 24–28-point content rhythm, and grouped 20-point cards. General contains real Timeline/Search shortcuts, launch-at-login state, and local-only status. | There is no telemetry, remote-update, or air-gap control: Local Memory is local-only by invariant, so presenting those switches would be misleading. |
| 3 — Search and filters | A composer is the unmistakable entry point; filters group time, website, and app with compact spatial controls | One shared composer switches explicitly between Search Memory and Ask Agent. Time uses pills, sites use removable host pills, and apps use recognizable tiles backed by the existing SearchSessionModel and filter owner. | Agent use is a separate bounded route, never an implicit escalation of an ordinary search. Search progressively adds visual matches and reports that state truthfully. |
| 4 — Agents Settings | Routing preferences precede installation/detection status and supporting clients scan as a compact list | Agents Settings retains the real access diagnostics, default bounded route, CLI state, grant scopes, and revocation entry points. | A target appears only when actual detection succeeds. No client logo, installed badge, or destination is fabricated; agents receive scoped result evidence rather than archive-wide access. |
| 5 — Appearance | Three visual mode previews make the setting comprehensible before selection; one accent organizes focus | System, Light, and Dark are persisted choices with previews. Fresh profiles default to Light; System leaves colorScheme unresolved so macOS appearance changes propagate dynamically; azure is the sole accent token. | Unsupported Dock-icon and timeline-visibility toggles are omitted. Dark mode uses semantic macOS surfaces instead of an inverted light palette. |
| 6 — Capture | Capture health and inactivity behavior are prioritized above tuning choices | Capture Settings exposes the real lifecycle state and action, foreground-window-only policy, fixed inactivity behavior, and truthful paused/unavailable/permission-loss/stopped states. | Unvalidated quality presets are omitted. Local Memory never relaxes foreground-window identity or launches capture during deterministic review. |
| 7 — Storage | Current usage is prominent and lifecycle policies are explained in plain language | Storage uses the real diagnostics snapshot for archive usage and states the validated 30-day and 20 GB defaults, deletion behavior, and metadata-key protection. | It never claims blanket encryption of visual media and does not offer an unvalidated “keep forever” or generic compression policy. |

## Cross-surface review

- Composition: the prior database-like sidebar/list/inspector shell is gone from the primary journey. Timeline and Search each have one dominant object.
- Hierarchy: primary actions use azure; evidence and destructive actions are reachable but visually subordinate; failures remain explicit and fail closed.
- Density and spacing: navigation is compact, content uses the existing four-point spacing scale, Settings cards use 20-point radii, and nested borders are avoided.
- Discoverability: arrows frame the moment spatially, the playhead anchors time, filters name their scope, and Ask Agent is an explicit route with scope messaging.
- Polish: semantic light/dark surfaces, hairlines, soft elevation, adaptive result columns, minimum-window fixtures, focus identifiers, VoiceOver labels, Increased Contrast, Reduce Motion-aware models, and pseudo-localization are retained.
- Identity: Local Memory uses its own product name, copy, fixture imagery, SF Symbols, semantic macOS colors, and privacy-specific gap language.

## Runtime boundary

The deterministic gallery covers 25 required states at both default and minimum sizes. Installed keyboard traversal, visible AppKit focus rings, VoiceOver reading order, live drag/scrub behavior, dynamic NSAppearance observation in a real window, ScreenCaptureKit permission-loss transitions, and media display remain unchanged H9 acceptance items on a known-safe validation Mac.
