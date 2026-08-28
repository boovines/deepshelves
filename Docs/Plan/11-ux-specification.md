# Concrete Native UX Specification

## Product posture

The app should feel like a quiet, trustworthy macOS utility, not a dashboard and not a browser page in a window. It records without demanding attention, makes recall fast from the keyboard, and always exposes whether capture is active. Native behavior and legibility outrank novelty.

SwiftUI and selective AppKit interop are the UI framework. `MemoryDesignSystem` standardizes tokens and composed controls. gluestack is not used because it targets React Native/Expo and would not supply native macOS focus, menus, windowing, accessibility, or energy behavior.

## Window model

| Surface | Geometry | Behavior |
|---|---|---|
| Menu-bar popover | 320 × content, maximum 520 high | Status, pause/resume, search, forget recent, settings, quit |
| Global search panel | 760 × 620, minimum 640 × 480 | Centered non-activating `NSPanel`; becomes key when invoked; remembers display |
| Main window | 1120 × 760 default; 840 × 560 minimum | Restorable; opens last section and selection |
| Sidebar | 184 default; 168...240 | Search, Timeline, Activity, Settings |
| Detail inspector | 264 default; 220...360 | Collapsible provenance/actions; hidden below 900-point width |
| Timeline rail | 96 high | Fixed beneath detail canvas; keyboard and pointer scrubbing |
| Settings window | 680 × 560 | Native toolbar sections; no modal wizard after onboarding |

The global search panel is a distinct scene backed by the same navigation/search state, not a second product implementation.

## Design tokens

### Color

Use semantic system colors through SwiftUI/AppKit bridges; never hard-code light appearance values.

| Token | macOS semantic source | Use |
|---|---|---|
| `surface.window` | `windowBackgroundColor` | Window/root |
| `surface.sidebar` | `underPageBackgroundColor` | Sidebar |
| `surface.control` | `controlBackgroundColor` | Cards, fields |
| `surface.selected` | `selectedContentBackgroundColor` at reduced opacity | Selection |
| `text.primary` | `labelColor` | Main labels |
| `text.secondary` | `secondaryLabelColor` | Metadata |
| `text.tertiary` | `tertiaryLabelColor` | Hints |
| `border.default` | `separatorColor` | Hairlines |
| `accent` | `systemIndigo` | Focus, active selection, primary action |
| `status.recording` | `systemRed` | Recording dot only |
| `status.paused` | `systemOrange` | Paused state |
| `status.success` | `systemGreen` | Verified completion |

No gradients. Materials may appear only in the menu popover and floating search chrome, using system material without custom tint. Screenshots remain color-neutral and never receive decorative overlays.

### Spacing, shape, and type

- Spacing scale: 4, 8, 12, 16, 24, 32 points.
- Corner radii: 6 for controls, 10 for cards, 14 for floating panels.
- Hairline: one physical pixel using display scale.
- Control heights: 28 compact, 32 standard, 36 search field.
- Typography: native `.caption`, `.footnote`, `.callout`, `.body`, `.headline`, `.title2`; monospaced digits for timecodes.
- Search result title: `.headline`, maximum one line. Evidence: `.callout`, maximum two lines. Metadata: `.caption`.
- Motion durations: 100 ms focus/hover, 180 ms selection/layout, 260 ms panel presentation. Honor Reduce Motion by replacing movement with opacity.
- Shadows: system window shadow only; cards use borders and surface contrast, not drop shadows.

## Reusable controls

`MemoryDesignSystem` owns:

- `MemorySearchField`
- `FilterToken` and `FilterTokenBar`
- `CaptureStatusBadge`
- `MemoryResultCard`
- `EvidenceSnippet`
- `TimelineRail` and `TimelineMarker`
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

    Search
      query + filters
      result grid
      selected result detail + timeline

    Timeline
      date navigation
      chronological visual filmstrip
      gaps and application transitions

    Activity
      day/week range
      hourly heatmap
      application totals
      explicit unrecorded gaps

    Settings
      Capture
      Privacy
      Storage
      Search & models
      Agent access
      About & diagnostics

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

## Global search

    ┌────────────────────────────────────────────────────────────┐
    │ 🔍  yellow lamp yesterday                 ⌘K clear   esc  │
    │ [Yesterday ×] [All apps ▾] [All sites ▾]                  │
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
- Parsing converts recognized time/app/site phrases into visible removable tokens. Query text remains editable and no hidden filter is applied.
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

    ┌──────────┬────────────────────────────────────┬────────────┐
    │ Search   │                                    │ 2:14:08 PM │
    │ Timeline │          screenshot canvas         │ Safari     │
    │ Activity │                                    │ example.com│
    │ Settings │                                    │ Evidence   │
    │          ├────────────────────────────────────┤ [Open]      │
    │          │  2:13  ▪ ▪ ▪ ┃●┃ ▪ ▪   gap   ▪   │ [Forget]    │
    └──────────┴────────────────────────────────────┴────────────┘

- Canvas uses aspect-fit, pixel-accurate zoom, and click-drag pan only when zoomed.
- Left/right steps searchable frames; Option-left/right steps application transitions; Command-left/right changes day.
- Scrubbing updates a low-resolution thumbnail immediately and the decoded full frame after 120 ms dwell.
- Gaps are visible labeled regions. Excluded content has no thumbnail and is never implied.
- Inspector shows timestamp, app, window title, approved host/path, match evidence and source, processing state, Open/Revisit, Export moment, and Forget moment.
- `Forget moment` explains that the underlying short video chunk will be rewritten. Confirmation defaults to Cancel and remains non-blocking while processing.
- Revisit launches the application and approved URL when available. It never attempts to restore form state or claim exact state restoration.

## Timeline section

The Timeline section opens to today, with day picker, jump-to-now, an app-color-neutral filmstrip, and hour separators. Zoom levels are 15 minutes, one hour, six hours, and one day. Application transitions are labeled at wider zooms and summarized at narrow zooms. Paused, idle, permission-loss, process-stopped, sleep, and excluded gaps have distinct accessible text labels but use patterns plus color so meaning does not depend on color.

## Activity

Activity is descriptive, never evaluative.

- Heatmap rows are days; columns are local clock hours; cell intensity represents recorded active minutes.
- Totals show recorded foreground duration per application and an explicit `Unrecorded` total.
- Daylight-saving changes use real elapsed time and label repeated/missing hours.
- No productivity score, attention score, streak, ranking, or normative language.
- Selecting a cell opens Timeline with that interval, subject to the same privacy filters.

## Settings

### Capture

Status, launch at login, global shortcut, `Foreground window only` as a fixed privacy mode, active/static/idle policy as read-only advanced details, and permission health. Advanced timing and full-display capture are not user-tunable in V1 because they would make privacy/performance outcomes indeterminate.

The menu and Capture Settings use one lifecycle projection. Recording, user-paused, idle,
sleep/lock, permission-required, low-disk, target-unavailable, and stopped states display
their exact cause while `Foreground window only` remains visible. Status may never say
Recording unless the coordinator currently permits capture for the exact active target.
Launch at login defaults off; its toggle is the only registration action. If macOS reports
approval required, show the Login Items instruction and keep the status unconfirmed.

### Privacy

Application exclusions, site exclusions, private-browser handling, temporary pause, `Forget last 15 minutes`, and policy-test preview. Rules show precedence and last-match behavior. If URL detection becomes unavailable, the row shows `Browser capture paused to protect site exclusions`.

### Storage

Archive location, current size, 30-day retention, 20-GB cap, oldest/newest moment, delete range, export, integrity check, and honest encryption copy: database text is app-encrypted; visual media is protected by macOS account permissions and FileVault when enabled.

### Search & models

Index progress, bundled MobileCLIP version/hash, reindex action, optional audio model installation state, and local benchmark status. No provider/API-key controls exist.

### Agent access

Helper install status, approved policies, expiry, last access time, result/image limits, revoke, and local audit entries. There is no “allow everything forever” toggle.

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

For every major surface, store deterministic baselines at default/minimum window size in light, dark, and Increased Contrast. Review checks alignment to the 4-point grid, focus ring visibility, truncation, empty/error states, screenshot aspect handling, and absence of custom web-like controls. A UI story is incomplete until its keyboard and VoiceOver path passes in addition to visual review.
