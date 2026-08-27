# Product Interface and Native Design System

## Outcome

Create a quiet, highly legible macOS product that feels authored rather than assembled by an agent. The interface uses native behavior, one governed token system, fixed interaction patterns, and screenshot-reviewed reference states.

Concrete dimensions, tokens, and wireframes are in [11-ux-specification.md](11-ux-specification.md).

## Framework decision

Use SwiftUI as the product and component framework, with AppKit only where SwiftUI lacks precise macOS behavior:

- MenuBarExtra and Window scenes
- NSPanel for the global search overlay
- NSVisualEffectView only for approved native material surfaces
- LazyVGrid by default; the measured S6 fallback may wrap NSCollectionView only for the hot result collection
- AVPlayer/AVPlayerItemVideoOutput for video-backed timeline detail
- Swift Charts for activity totals; custom Canvas for the day/hour heatmap
- SF Symbols and system typography

Do not use Tauri, React, shadcn, Base UI, gluestack, or a general web component library.

gluestack is appropriate for React Native/Expo, not a native macOS-only application. SwiftUI gives standardized focus, keyboard, VoiceOver, control sizing, dynamic colors, materials, and window behavior with fewer visual seams.

## Design-system package

MemoryDesignSystem owns:

- DesignTokens
- MemorySearchField
- FilterToken and FilterTokenBar
- CaptureStatusBadge
- MemoryResultCard
- EvidenceSnippet
- TimelineRail and TimelineMarker
- ActivityHeatmap
- PermissionRow and PrivacyRuleRow
- EmptyStateView
- InlineErrorView
- ProgressStatusView
- DestructiveConfirmationSheet

Feature packages may use native SwiftUI controls directly only through an approved semantic style or wrapper. Raw colors, fonts, corner radii, and shadows are forbidden outside MemoryDesignSystem.

## Visual language

- Native window background and grouped surfaces
- One system-indigo accent
- System red only for destructive actions
- Thin system separators
- SF Pro through SwiftUI text styles
- SF Mono only for IDs, paths, and diagnostic values
- 4-point spacing grid
- Small radii; no excessive pills
- No decorative gradients
- No generic glassmorphism
- Material only in the menu-bar popover and search panel
- Motion communicates state and spatial continuity, never decoration

Use system colors rather than hard-coded light/dark palettes wherever possible.

## Information architecture

### Menu bar

- Current state: Recording, Paused, Permission Required, Disk Full, or Indexing
- Open Search
- Open Timeline
- Pause/Resume
- Forget Last 15 Minutes
- Settings
- Quit

The menu-bar icon changes shape/fill rather than relying only on color.

### Global search

- Opens through one configurable global shortcut
- Always starts focused
- Parses app/site/time tokens visibly
- Shows recent filters before typing
- Shows a virtualized screenshot grid after results arrive
- Arrow keys navigate, Return opens, Space previews, Escape closes
- Command-1/2/3/4 switches Search/Timeline/Activity/Settings in the main window

### Main window

- Search
- Timeline
- Activity
- Settings

Open to the last meaningful location. Do not add a generic dashboard or chat-first home screen.

### Search results

Each screenshot card contains:

- Thumbnail preserving the captured foreground-window aspect inside a consistent card frame
- Application icon and title
- Local timestamp
- One evidence line
- Match-source indicator available on hover/focus, not permanent chrome

Cards never present generated text without labeling it.

### Detail

- Large screenshot/video frame
- Exact date/time and timezone
- Application, window, and site provenance
- Matched text with source and confidence
- Previous/next meaningful moment
- 96-point timeline with neutral segments, labeled application transitions, and patterned gaps
- Open/revisit when safe
- Delete this moment or a time range

### Activity

- Day/hour activity heatmap
- Active, captured, idle, paused, and missing time
- Application totals
- Date range

The UI calls these activity estimates, never productivity.

### Settings

- Recording: launch at login, cadence summary, cursor, pause shortcut
- Privacy: applications, sites, private-window handling, recent deletion
- Storage: retention, cap, current usage, FileVault status
- Search: model/index status and reindex
- Agents: clients, scopes, local access history
- Audio: separate opt-in and model/storage controls
- Data: export, delete all, recovery
- Diagnostics: queues, last capture, errors, local-only verification

## Component governance

1. Every reusable control has light, dark, focused, disabled, error, and large-content fixtures.
2. Interactive controls have VoiceOver labels and keyboard behavior before use in a feature.
3. Every screen has deterministic reference screenshots at default and minimum window sizes.
4. Feature code may not introduce raw visual constants.
5. New tokens require a design-system test and an entry in the token table.
6. Animations must use approved motion tokens and respect Reduce Motion.
7. Every destructive flow uses native confirmation and states exactly what media/text will be removed.
8. Layouts must work at minimum size and with 125% content-size stress.

## Testing

- SwiftUI previews for rapid inspection
- Custom NSHostingView screenshot harness for macOS reference images
- XCUITest for keyboard paths, global search, focus restoration, and dialogs
- Accessibility audits for labels, roles, focus order, and contrast
- Manual VoiceOver pass at each phase gate
- Performance fixture with 10,000 result cards and a full-day timeline

Do not rely on a snapshot library that only supports UIKit rendering. The project owns a small macOS NSImage renderer so output remains deterministic.

## Milestones

### U1 Design foundations

Gate: token catalog and all primitives match [11-ux-specification.md](11-ux-specification.md) in light/dark mode.

### U2 Shell and onboarding

Gate: menu bar, permission flow, main window, shortcut, and state restoration behave like a native utility.

### U3 Search and result grid

Gate: complete search-to-detail journey works without a mouse and remains smooth with the 10,000-card fixture.

### U4 Timeline and activity

Gate: scrub, select, zoom, and date navigation stay responsive across a generated 30-day archive.

### U5 Settings and trust

Gate: every privacy/storage/agent action exposes current state, effect, and recovery limitations.

## Sources

- [Apple Human Interface Guidelines for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos)
- [Apple SwiftUI](https://developer.apple.com/documentation/swiftui)
- [Apple MenuBarExtra](https://developer.apple.com/documentation/swiftui/menubarextra)
- [Apple Charts](https://developer.apple.com/documentation/charts)
- [gluestack, evaluated but not selected](https://github.com/gluestack/gluestack-ui)
