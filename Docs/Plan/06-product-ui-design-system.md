# Product Interface and Native Design System

## Outcome

Create a quiet, highly legible visual-memory product that feels authored rather than
assembled. One approved foreground-window screenshot is the dominant object; navigation,
search, provenance, and trust controls support it without competing with it. The interface
uses native behavior, one governed token system, fixed interaction patterns, and
snapshot-reviewed reference states.

Concrete dimensions, tokens, and wireframes are in [11-ux-specification.md](11-ux-specification.md).

## Framework decision

Use SwiftUI as the product and component framework, with AppKit only where SwiftUI lacks precise macOS behavior:

- MenuBarExtra and Window scenes
- NSPanel for the global search overlay
- NSVisualEffectView only for approved native material surfaces
- LazyVGrid by default; the measured S6 fallback may wrap NSCollectionView only for the hot result collection
- NSHostingView for deterministic synthetic offscreen snapshots only
- Swift Charts for activity totals; custom Canvas for the day/hour heatmap
- SF Symbols and system typography

Do not use Tauri, React, shadcn, Base UI, gluestack, or a general web component library.

gluestack is appropriate for React Native/Expo, not a native macOS-only application. SwiftUI gives standardized focus, keyboard, VoiceOver, control sizing, dynamic colors, materials, and window behavior with fewer visual seams.

## Design-system package

MemoryDesignSystem owns:

- DesignTokens
- MemorySearchField
- MemoryComposer and MemoryComposerRoutePicker
- FilterToken and FilterTokenBar
- ApplicationFilterTile
- CaptureStatusBadge
- MemoryResultCard
- EvidenceSnippet
- MemoryCanvasChrome and SecondaryDisclosure
- TimelineRail, TimelineInterval, TimelineMarker, and TimelinePlayhead
- SettingsSidebar, SettingsGroupCard, SettingsRow, and AppearancePreview
- ActivityHeatmap
- PermissionRow and PrivacyRuleRow
- EmptyStateView
- InlineErrorView
- ProgressStatusView
- DestructiveConfirmationSheet

Feature packages may use native SwiftUI controls directly only through an approved semantic style or wrapper. Raw colors, fonts, corner radii, and shadows are forbidden outside MemoryDesignSystem.

## Visual language

- Light: warm semantic window canvas, subtly tinted sidebar, white grouped surfaces
- Dark: purpose-designed semantic window/sidebar/card surfaces, never color inversion
- System: dynamically follows the effective `NSAppearance`
- Fresh profile default: Light
- One restrained semantic azure accent
- System red only for destructive actions
- Thin semantic hairlines and soft, restrained elevation
- SF Pro through SwiftUI text styles
- SF Mono only for IDs, paths, and diagnostic values
- 4-point spacing grid
- 18–22 point grouped-card radius; compact pills only for filters, status, and time
- 20–28 point spacing between major settings sections
- No decorative gradients
- No generic glassmorphism
- Material only in the menu-bar popover and search panel
- Motion makes selection and scrubbing spatial, interruptible, and immediate; Reduce Motion
  substitutes opacity/state change without losing feedback

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
- Presents a large composer with explicit `Search Memory` and `Ask Agent` routes
- Parses app/site/time tokens visibly
- Shows a filter disclosure with compact time pills, site tokens, and recognizable app tiles
- Shows a virtualized screenshot grid after results arrive
- Uses the one root-owned SearchSessionModel shared with the main window
- Creates agent requests only through bounded, expiring CLI/MCP policies
- Arrow keys navigate, Return opens, Space previews, Escape closes
- Command-1/2/3/4 switches Search/Timeline/Activity/Settings in the main window

### Main window

- Timeline is primary and centers one large screenshot canvas
- Compact Search and Settings actions live in restrained window chrome
- Previous/next controls flank the canvas
- Selected date/time anchors the lower-leading canvas edge
- A persistent bottom rail exposes app intervals, app symbols, patterned gaps, draggable
  playhead, and real zoom controls
- Search, Activity, and Settings remain first-class destinations without a permanently
  visible database sidebar

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

- Large aspect-fit foreground-window screenshot frame
- Exact date/time and timezone
- Application, window, and site provenance
- Matched text with source and confidence
- Previous/next meaningful moment
- Persistent timeline with app-colored intervals, application symbols, labeled transitions,
  and patterned gaps; meaning never relies on color alone
- Open/revisit when safe
- Delete this moment or a time range
- Provenance, evidence, Revisit, Export, and Forget appear in secondary disclosure

### Activity

- Day/hour activity heatmap
- Active, captured, idle, paused, and missing time
- Application totals
- Date range

The UI calls these activity estimates, never productivity.

### Settings

- General: Timeline/Search shortcuts, launch at login, truthful local-only/offline status
- Agents: default detected target, CLI state, bounded policies, revocation, local audit
- Appearance: System/Light/Dark previews, persisted selection, semantic accent choices
- Capture: exact lifecycle state, foreground-window-only invariant, inactivity pause, permission
  recovery; quality presets appear only after real parameter validation
- Storage: actual usage, truthful 30-day/20-GB lifecycle defaults, archive health, exact
  database-versus-visual-media protection copy
- Exclusions: application/site rules, add/remove/reorder, current-context test, immediate
  fail-closed application

The sidebar is 240–280 points. Content uses a large title/subtitle and spacious grouped
cards. Supported agent targets and installation state are shown only from real detection.
Dock-icon and timeline-control visibility are omitted unless the app can actually apply
them. No telemetry or remote-update control is offered because those behaviors do not exist.

## Component governance

1. Every reusable control has light, dark, focused, disabled, error, and large-content fixtures.
2. Interactive controls have VoiceOver labels and keyboard behavior before use in a feature.
3. Every screen has deterministic synthetic offscreen snapshots at default and minimum
   window sizes. They are not application-runtime evidence.
4. Feature code may not introduce raw visual constants.
5. New tokens require a design-system test and an entry in the token table.
6. Animations must use approved motion tokens and respect Reduce Motion.
7. Every destructive flow uses native confirmation and states exactly what media/text will be removed.
8. Layouts must work at minimum size and with 125% content-size stress.
9. Fresh profiles default to Light; persisted System mode follows effective appearance
   changes dynamically.
10. Every visible control has a real action, state mutation, or navigation outcome.

## Testing

- SwiftUI previews for rapid inspection
- Custom NSHostingView synthetic offscreen renderer whose source audit proves it cannot
  initialize the product, capture, Apple ImageIO, VideoToolbox, AVAssetWriter, or media code
- XCUITest for keyboard paths, global search, focus restoration, and dialogs
- Accessibility audits for labels, roles, focus order, and contrast
- Manual VoiceOver pass at each phase gate
- Performance fixture with 10,000 result cards and a full-day timeline

Do not rely on a snapshot library that only supports UIKit rendering. The project owns a
small macOS renderer so output remains deterministic. On the owner's laptop it renders only
synthetic SwiftUI shapes/text and writes raw bitmap output through the audited nonmedia
path; installed-app and media-backed screenshots remain H9-only.

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
