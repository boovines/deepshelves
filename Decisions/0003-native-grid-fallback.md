# ADR 0003: AppKit collection for the measured hot result grid

- Status: Accepted
- Date: 2026-08-28
- Story: LM-008
- Spike: S6

## Context

The S6 prototype first used a pure SwiftUI `LazyVGrid` for 10,000 deterministic cards. A distant programmatic scroll stalled after card 5,468 and remained active for more than 120 seconds. The preserved sample and outcome are under `Benchmarks/Results/S6/rehearsal-swiftui/`. This failed the required fast-scroll behavior and triggered the sole fallback authorized by plan 12.

## Decision

Replace only the hot 10,000-card collection with an `NSCollectionView` exposed through `NSViewRepresentable`. Retain SwiftUI for the search panel, detail composition, timeline, controls, state binding, appearance, localization, and accessibility surfaces. Retain `MemoryDesignSystem` constants, stable card identifiers, selection-generation cancellation, and the actor-owned source-HEIC decode cache.

The collection uses native item reuse and O(1) indexed scrolling. This is not permission to migrate other surfaces to AppKit or to introduce a web UI.

## Consequences

- The result collection scales independently of SwiftUI view-tree growth while presenting the same stable selection state.
- Accessibility identifiers and labels remain available to signed XCUITest.
- SwiftUI remains the product composition layer and all nonmeasured surfaces stay native SwiftUI.
- Later LM-041 must carry forward this narrow wrapper unless a new measurement proves a lazy SwiftUI implementation satisfies the same gates.

## Verification

The signed Release XCUITest drives search, card selection, a 24-hour timeline, warm presentation, appearance, 40%-expanded pseudo-localization, resize, and keyboard traversal. `scripts/check-s6-ui-spike.sh` enforces cold/warm focus, 60-card render, 55 fps p95, 750 MB RSS, scrub/decode latency, stale-selection, accessibility, and unclipped-control gates. The canonical screenshot, raw samples, result bundle summary, and signatures are linked from `Results/LM-008/report.json`.
