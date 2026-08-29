# Concrete Native UX Specification

## Product posture

The app should feel like a quiet, trustworthy visual memory, not a dashboard, database
browser, or browser page in a window. The selected foreground-window screenshot is the
primary object. Controls are compact, spatial, and disclosed at the moment they are useful;
capture truth remains continuously available. Native behavior and legibility outrank
novelty.

SwiftUI and selective AppKit interop are the UI framework. `MemoryDesignSystem` standardizes tokens and composed controls. gluestack is not used because it targets React Native/Expo and would not supply native macOS focus, menus, windowing, accessibility, or energy behavior.

## Window model

| Surface | Geometry | Behavior |
|---|---|---|
| Menu-bar popover | 320 × content, maximum 520 high | Status, pause/resume, search, forget recent, settings, quit |
| Global search panel | 760 × 620, minimum 640 × 480 | Centered non-activating `NSPanel`; becomes key when invoked; remembers display |
| Main window | 1180 × 800 default; 880 × 600 minimum | Restorable; opens the last meaningful Timeline/Search/Activity location |
| Main chrome | 52 high | Compact Search and Settings actions; no permanent database sidebar |
| Secondary disclosure | 320 preferred; sheet/popover at minimum width | Provenance, evidence, Revisit, Export, and Forget |
| Timeline rail | 104 high | Persistent beneath canvas; pointer/keyboard scrub, app intervals, playhead, zoom |
| Settings window | 1040 × 720; 840 × 600 minimum | 260-point sidebar and independently scrolling content |
| Settings sidebar | 260 default; 240...280 | General, Agents, Appearance, Capture, Storage, Exclusions |

The global search panel is a distinct scene backed by the same navigation/search state, not a second product implementation.

## Design tokens

### Color

Use semantic system colors through SwiftUI/AppKit bridges; never hard-code light appearance values.

| Token | macOS semantic source | Use |
|---|---|---|
| `surface.window` | semantic warm-window resolver | Window/root; warm white in Light, authored dark surface in Dark |
| `surface.sidebar` | semantic sidebar resolver | Slightly tinted Light sidebar and distinct Dark sidebar |
| `surface.control` | semantic raised-surface resolver | White Light cards and elevated Dark cards |
| `surface.selected` | `selectedContentBackgroundColor` at reduced opacity | Selection |
| `text.primary` | `labelColor` | Main labels |
| `text.secondary` | `secondaryLabelColor` | Metadata |
| `text.tertiary` | `tertiaryLabelColor` | Hints |
| `border.default` | `separatorColor` | Hairlines |
| `accent` | semantic azure resolver | Focus, active selection, primary action, playhead |
| `status.recording` | `systemRed` | Recording dot only |
| `status.paused` | `systemOrange` | Paused state |
| `status.success` | `systemGreen` | Verified completion |

No decorative gradients. Materials may appear only in the menu popover, composer, and
compact floating canvas chrome, using system material without a custom tint. Screenshots
remain color-neutral and never receive decorative overlays. Fresh profiles resolve to
Light. System mode follows the effective `NSAppearance` dynamically.

### Spacing, shape, and type

- Spacing scale: 4, 8, 12, 16, 20, 24, 28, 32 points.
- Corner radii: 8 for compact controls, 12 for screenshot/result cards, 20 for grouped
  settings/composer surfaces, 22 for the primary canvas container.
- Hairline: one physical pixel using display scale.
- Control heights: 28 compact, 32 standard, 36 search field.
- Typography: native `.caption`, `.footnote`, `.callout`, `.body`, `.headline`, `.title2`; monospaced digits for timecodes.
- Search result title: `.headline`, maximum one line. Evidence: `.callout`, maximum two lines. Metadata: `.caption`.
- Motion durations: 100 ms focus/hover, 180 ms selection/layout, 260 ms panel presentation. Honor Reduce Motion by replacing movement with opacity.
- Shadows: restrained semantic elevation on major floating/grouped surfaces; never stack a
  heavy border and shadow or place cards inside visually redundant cards.

## Reusable controls

`MemoryDesignSystem` owns:

- `MemorySearchField`
- `MemoryComposer` and route control
- `FilterToken` and `FilterTokenBar`
- `ApplicationFilterTile`
- `CaptureStatusBadge`
- `MemoryResultCard`
- `EvidenceSnippet`
- `MemoryCanvasChrome` and `SecondaryDisclosure`
- `TimelineRail`, `TimelineInterval`, `TimelineMarker`, and `TimelinePlayhead`
- `SettingsSidebar`, `SettingsGroupCard`, `SettingsRow`, and `AppearancePreview`
- `ActivityHeatmap`
- `PermissionRow`
- `PrivacyRuleRow`
- `EmptyStateView`
- `InlineErrorView`
- `ProgressStatusView`
- `DestructiveConfirmationSheet`

Every control ships with SwiftUI previews for normal, hover, pressed, focused, disabled, selected, loading, error, light, dark, Increased Contrast, and at least one long-localized-text case. Icon-only controls require a tooltip and accessibility label.

## Information architecture

    Menu bar
      status / pause / search / forget / settings

    Timeline
      dominant selected screenshot
      previous / next moment
      date and time
      persistent spatial rail
      provenance / actions disclosure

    Search
      Search Memory / Ask Agent composer
      time / website / application filters
      result grid
      selected result opens visual Timeline context

    Activity
      day/week range
      hourly heatmap
      application totals
      explicit unrecorded gaps

    Settings
      General
      Agents
      Appearance
      Capture
      Storage
      Exclusions

## Onboarding

Onboarding is a single window with a four-step sidebar. Users may quit and resume without losing progress.

    ┌──────────────────────────────────────────────────────┐
    │ Local Memory                                         │
    ├───────────────┬──────────────────────────────────────┤
    │ 1 Welcome     │ Your screen memory stays on this Mac │
    │ 2 Permissions │ [Screen Recording]  Required  [Open] │
    │ 3 Privacy     │ [Accessibility]      Recommended     │
    │ 4 Ready       │ [Launch at Login]    On              │
    │               │                                      │
    │               │ What is stored / what is not         │
    │               │ [Back]                    [Continue]  │
    └───────────────┴──────────────────────────────────────┘

Required Screen Recording permission is requested only after the user presses `Open System Settings`. Accessibility is explained as improving text quality and context, then requested separately. Microphone never appears until the user enables audio in Settings. “Ready” shows the menu-bar icon, pause shortcut, archive location, default 30-day/20-GB retention, and a live recording preview.

The preview and privacy copy explicitly say: `Local Memory records only your active window. Background windows, notifications, the Dock, and the desktop are not stored.` The preview must demonstrate this by placing a second fixture window behind the approved target and showing that it is absent from the saved image.

If permission is denied, the app remains navigable with recording off and shows an exact recovery action. It never loops system prompts.

## Search and agent composer

    ┌────────────────────────────────────────────────────────────┐
    │ [Search Memory | Ask Agent]                                │
    │ 🔍  yellow lamp yesterday                         Return  │
    │ [Yesterday ×] [Applications 2] [Sites 1] [Filters]        │
    ├────────────────────────────────────────────────────────────┤
    │  8 results                                      Grid ▾    │
    │ ┌───────────┐ ┌───────────┐ ┌───────────┐                  │
    │ │ screenshot│ │ screenshot│ │ screenshot│                  │
    │ │ 2:14 PM   │ │ 1:48 PM   │ │ 11:06 AM  │                  │
    │ │ Safari    │ │ Preview   │ │ Notes     │                  │
    │ │ visual hit│ │ “lamp…”   │ │ visual hit│                  │
    │ └───────────┘ └───────────┘ └───────────┘                  │
    └────────────────────────────────────────────────────────────┘

- The insertion point is focused on open.
- Search Memory submits to the existing root-owned `SearchSessionModel` and hybrid
  `SearchEngine`; the global panel and main Search destination do not create a second owner.
- Ask Agent first constructs/reuses an explicit bounded access policy. It is unavailable
  without a real detected target and never grants all history, unlimited results, perpetual
  access, or images without separate opt-in.
- Parsing converts recognized time/app/site phrases into visible removable tokens. Query text remains editable and no hidden filter is applied.
- The filter panel groups compact Today/Yesterday/Last week/custom-date pills, approved host
  tokens, and app tiles made from real app metadata/icons or honest SF Symbol fallbacks.
- Results stream lexical matches first only if visual scoring is still running; order settles once, with an `Adding visual matches…` status. Cards do not continually reshuffle.
- Default three-column grid becomes two below 720 points and one below 520.
- Up/down moves spatially; left/right moves within row; Return opens detail; Space Quick Looks; Command-Return opens the source app/URL when safe; Escape returns or closes.
- A card shows thumbnail, local date/time, app icon/name, optional host, and evidence. It never fabricates a summary.

States:

- Empty archive: `Your screen memory will appear here after recording begins.` with `Check capture status`.
- Empty query: recent time groups and suggested examples drawn from indexed capabilities, not user content.
- Loading under 300 ms: no spinner. Over 300 ms: quiet inline progress.
- No result: restate active filters and offer individual filter removal.
- Indexing backlog: return available results and show `Still indexing 126 moments`.
- Search failure: preserve query/tokens and expose `Try again` plus local diagnostic code.

## Result detail and timeline

    ┌────────────────────────────────────────────────────────────┐
    │ [Search]               Local Memory              [Settings]│
    │                                                            │
    │  ‹          approved foreground-window screenshot       ›  │
    │                                                            │
    │  Aug 29, 2:14 PM                         [Details & actions]│
    ├────────────────────────────────────────────────────────────┤
    │ app intervals + symbols       │playhead│        [−] [＋]   │
    └────────────────────────────────────────────────────────────┘

- Canvas uses aspect-fit, pixel-accurate zoom, and click-drag pan only when zoomed.
- Left/right steps searchable frames; Option-left/right steps application transitions; Command-left/right changes day.
- Scrubbing updates a low-resolution thumbnail immediately and the decoded full frame after 120 ms dwell.
- Gaps are visible labeled regions. Excluded content has no thumbnail and is never implied.
- Secondary disclosure shows timestamp, app, window title, approved host/path, match evidence
  and source, processing state, Open/Revisit, Export moment, and Forget moment.
- `Forget moment` explains that the underlying short video chunk will be rewritten. Confirmation defaults to Cancel and remains non-blocking while processing.
- Revisit launches the application and approved URL when available. It never attempts to restore form state or claim exact state restoration.

## Timeline section

The Timeline section opens to today and directly owns the dominant canvas. Zoom levels are
15 minutes, one hour, six hours, and one day. App intervals use stable semantic accent
families and actual/fallback app symbols; text/patterns preserve meaning without color.
Dragging the playhead immediately selects the nearest safe thumbnail and promotes the exact
full frame only after the existing dwell contract. Paused, idle, permission-loss,
process-stopped, sleep, and excluded gaps remain explicit and never imply missing pixels.

## Activity

Activity is descriptive, never evaluative.

- Heatmap rows are days; columns are local clock hours; cell intensity represents recorded active minutes.
- Totals show recorded foreground duration per application and an explicit `Unrecorded` total.
- Daylight-saving changes use real elapsed time and label repeated/missing hours.
- No productivity score, attention score, streak, ranking, or normative language.
- Selecting a cell opens Timeline with that interval, subject to the same privacy filters.

## Settings

Settings uses a 240–280 point left sidebar, large section title/subtitle, 20–28 point section
spacing, and 18–22 point grouped cards. Each row has one primary label, optional secondary
truth/recovery copy, a leading SF Symbol tile, and a trailing native action/status. No
control is decorative.

### General

Timeline and Search shortcuts, launch at login, and a fixed local-only/offline status. No
telemetry, analytics, cloud-sync, favicon-service, or remote-update setting exists.

### Agents

Default routing target, CLI enable/install state, detected supported clients, bounded policy
creation/review/revoke, and content-free local access history. Installation badges are shown
only from real detection. No unrestricted or forever option exists.

### Appearance

System, Light, and Dark choices use visual semantic previews. Fresh profiles default to
Light; selection persists; System follows the current effective macOS appearance. A small
semantic accent palette may be offered. Dock-icon and timeline-control visibility are
omitted until they are genuinely supported.

### Capture

Status, launch at login, global shortcut, `Foreground window only` as a fixed privacy mode, active/static/idle policy as read-only advanced details, and permission health. Advanced timing and full-display capture are not user-tunable in V1 because they would make privacy/performance outcomes indeterminate.

The menu and Capture Settings use one lifecycle projection. Recording, user-paused, idle,
sleep/lock, permission-required, low-disk, target-unavailable, and stopped states display
their exact cause while `Foreground window only` remains visible. Status may never say
Recording unless the coordinator currently permits capture for the exact active target.
Launch at login defaults off; its toggle is the only registration action. If macOS reports
approval required, show the Login Items instruction and keep the status unconfirmed.

Pause-on-inactivity mutates the real capture coordinator preference. Capture-quality presets
remain omitted until H9 validates distinct real capture parameters. Permission loss,
unavailable target, stopped, and paused are visibly distinct.

### Exclusions

Application exclusions, site exclusions, private-browser handling, temporary pause, `Forget last 15 minutes`, and policy-test preview. Rules show precedence and last-match behavior. If URL detection becomes unavailable, the row shows `Browser capture paused to protect site exclusions`.

### Storage

Archive location, current size, 30-day retention, 20-GB cap, oldest/newest moment, delete range, export, integrity check, and honest encryption copy: database text is app-encrypted; visual media is protected by macOS account permissions and FileVault when enabled.

Search/index health, diagnostics, export, archive repair, and delete-all remain reachable
through secondary rows in Storage or the relevant disclosure without adding a seventh
sidebar category.

## Menu-bar behavior

- Icon: neutral outline while active with a tiny red status dot; pause bars when paused; warning badge on permission/storage failure.
- First row spells out `Recording`, `Paused`, or `Recording unavailable`; status is never conveyed only by icon/color.
- Primary item toggles Pause/Resume and shows shortcut.
- `Search Memory…`, `Forget Last 15 Minutes…`, `Open Local Memory`, `Settings…`, and `Quit` follow standard ellipsis/menu conventions.
- Forget uses a confirmation sheet and displays completion/failure in the popover.

## Keyboard map

| Shortcut | Action |
|---|---|
| Configurable global shortcut, default `⌥Space` | Open/close search panel |
| `⌘F` | Focus search in current window |
| `⌘1` / `⌘2` / `⌘3` / `⌘,` | Search / Timeline / Activity / Settings |
| `⌘[` / `⌘]` | Back / forward selection history |
| `Space` | Quick Look selected moment |
| `Return` | Open detail |
| `⌘Return` | Revisit source |
| `⌥←` / `⌥→` | Previous/next application transition |
| `⌘Delete` | Forget selected moment, with confirmation |
| `Escape` | Close transient UI or move back one level |

No global shortcut deletes data or pauses recording without visible feedback.

## Accessibility and localization

- Full keyboard traversal follows visual order and restores focus after panels/sheets close.
- Every screenshot card announces time, app, host, evidence type, and position in results.
- Timeline exposes markers and gaps as an accessibility list in addition to the visual rail.
- Heatmap has a table representation with date, hour, recorded minutes, and gap minutes.
- Minimum target 24 × 24, minimum body text 11 points, system text scaling respected where macOS supports it.
- Test English pseudo-localization at +40% length. Dates, clocks, week starts, and relative phrases use locale-aware Foundation APIs.

## Screenshot review gate

Store deterministic synthetic offscreen snapshots at default and minimum size for Timeline
(populated, empty, gap, corrupt frame, loading), Search (initial, filtered, results, no
results, adding visual matches, error), Agent composer (unavailable, ready, permission
denied), and every Settings section. Cross-cut those states with Light, Dark, System semantic
resolution, Increased Contrast, and pseudo-localization without multiplying identical files
when a deterministic matrix manifest proves coverage.

Review checks alignment to the 4-point grid, focus visibility, truncation, empty/error
states, screenshot aspect handling, semantic appearance, and absence of fake controls. Safe
offscreen snapshots, unit tests, keyboard models, accessibility models, static audits, and
compile checks establish implementation readiness only. Actual application keyboard,
VoiceOver, window, drag, NSWorkspace, client-detection, and media behavior remain H9 runtime
items. A major surface is not implementation-ready until all of its safe evidence passes and
is not accepted until its H9 evidence also passes.
