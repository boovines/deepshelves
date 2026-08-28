# Platform, Foreground-Window Capture, and Runtime Infrastructure

## Outcome

Provide a resilient native macOS runtime that records enough visual continuity for Coast-style recall without ever persisting unreviewed pixels from background windows. The canonical visual surface is one approved foreground window, not the display.

## Non-negotiable visual privacy invariant

> Every persisted pixel must originate from the uniquely resolved, policy-approved foreground window for the same capture epoch.

The product never records the desktop as a composited display image. Therefore a password manager, notification, private browser page, chat window, or other sensitive surface behind or beside the active window cannot leak into the frame.

Consequences:

- Desktop wallpaper, Dock, menu bar, notifications, and unrelated windows are absent.
- Occluding windows do not appear over the approved target.
- A separate menu, tooltip, popover, or sheet is captured only if it becomes the uniquely resolved focused window itself.
- When no eligible focused window can be resolved, record a typed metadata-only gap and no pixels.
- Full-display capture is outside V1 and can be introduced only through a privacy ADR with pixel-contamination fixtures.

This intentionally sacrifices some ambient spatial context for a much stronger and explainable local-privacy guarantee.

## Fixed implementation

- Swift 6 native application
- SwiftUI lifecycle with focused AppKit interop
- `MenuBarExtra` plus a normal main window
- ScreenCaptureKit `SCStream`
- `SCContentFilter(desktopIndependentWindow:)` for exactly one `SCWindow`
- `SCStream.updateContentFilter` when the approved focused window changes
- Image I/O HEIC encoding behind an injectable frame-encoder boundary
- NSWorkspace for application and sleep/wake events
- Accessibility AX APIs for focused window, URL, and structured content
- Coarse CGEventTap event classes only to detect user activity
- SMAppService for opt-in launch at login
- OSLog with privacy-sensitive values omitted

Do not fork Screenpipe or add Tauri/Rust/Python helpers. Independent implementations may be studied for behavior and benchmarks only.

## Runtime topology

    NSWorkspace + AX focused window + SCShareableContent
                         |
                  WindowResolver actor
                         |
                  PrivacyPolicy actor
                         |
             approved WindowCaptureEpoch
                         |
        SCStream single-window content filter
                         |
      epoch/context/policy recheck before append
                         |
            MediaWriter + DatabaseWriter

`CaptureCoordinator` owns `WindowResolver`, `ScreenStream`, `ContextMonitor`, `PrivacyPolicy`, and `ActivityMonitor`. Media, database, enrichment, and search actors remain separate. The main actor performs no capture, OCR, encoding, database I/O, or vector work.

## Focused-window resolution

`WindowResolver` obtains the foreground process and focused/top-level AX window, then maps it to current `SCWindow` candidates using public APIs only:

1. Require the AX element and `SCWindow.owningApplication` to have the same process ID.
2. Convert AX position/size into ScreenCaptureKit screen coordinates and require edge deltas within 4 points or rectangle intersection-over-union of at least 0.90.
3. If more than one candidate remains, use exact normalized title only as a tie-breaker.
4. Require exactly one result; otherwise fail closed.

The candidate must be on screen, normal capture content, owned by the foreground process, and intersect the main display in V1. Resolution must be unique. Ambiguous, missing, minimized, secondary-display-only, protected, zero-size, desktop, and system-secure surfaces produce no pixels and a typed gap:

- `unresolvedWindow`
- `ambiguousWindow`
- `minimizedWindow`
- `unsupportedDisplay`
- `protectedSurface`
- `noWindow`

Refresh `SCShareableContent` on foreground/window transitions and when the prior identifier disappears. Do not continuously enumerate it for each frame.

Do not call private or underscored APIs such as `_AXUIElementGetWindow`. A public-API resolver miss is a metadata-only gap, not permission to guess.

## Capture epochs and stale-frame defense

Every target change creates a `WindowCaptureEpoch` containing:

- random epoch UUID
- target `SCWindow.windowID`
- owning process ID and bundle ID
- approved normalized window bounds
- browser context/policy-decision ID
- filter-applied monotonic timestamp

Sequence:

1. Resolve the unique target.
2. Evaluate app/window/private/browser policy.
3. Flush pending candidates and close the prior media chunk.
4. Apply `SCContentFilter(desktopIndependentWindow:)` with `updateContentFilter`.
5. Start the epoch only after the update succeeds.
6. Tag delivered frames with the current epoch.
7. Immediately before append, verify epoch ID, current focused-window identity, policy, frame dimensions, and target-window identity.
8. Reject every frame delivered before the successful filter-update timestamp or after any target/context change.

SCStream may deliver stale buffers around filter changes; no buffer is trusted merely because it arrived after the API call began.

## Stream configuration

- One long-lived stream, filtering one approved foreground window at a time
- Maximum encoded long edge 1920 pixels, preserving target-window aspect ratio
- Bi-planar 4:2:0 pixel format suitable for hardware encoding
- Receive up to 2 fps while active
- Queue depth 3
- Cursor visible when it lies within the target window
- Audio disabled

The stream is stopped or left without an eligible target during gaps. Configuration/filter changes occur after focus changes, window resize, wake, or display change.

## Frame acceptance

Receiving and persistence are separate:

1. Receive at up to two frames per second for the current approved epoch.
2. Reject stale/mismatched epoch, focus, policy, window, and dimension states.
3. Compute a 64 × 64 luminance difference/perceptual signature.
4. Accept immediately after a new approved epoch begins.
5. While target content changes, accept at most one frame per second.
6. Index at most one accepted frame every two seconds plus the first epoch frame.
7. While static, accept one 30-second heartbeat.
8. After five minutes idle, stop accepting until activity or target change.

Metadata-only gaps preserve timeline honesty when visual capture is unavailable.

## HEIC keyframe chunks

MediaWriter creates immutable logical chunk directories of independently encoded HEIC frames scoped to one capture epoch and one encoded dimension:

- Maximum duration 30 seconds
- End immediately on target-window, epoch, or encoded-size change
- Image I/O HEIC encoder; no AVAssetWriter or VideoToolbox encoder in the shipping path
- Every accepted frame is independently decodable
- Source presentation timestamps preserved as ordered logical times
- Per-frame byte count and SHA-256 in a canonical chunk manifest
- Exact frame asset path carried by each searchable frame
- Atomic per-frame partial publication inside staging, then atomic whole-directory rename, fsync, and database commit

ADR 0001 authorizes HEIC as the canonical archive format after two repeatable hardware-video kernel panics during LM-025. Production Image I/O encoding is compile-checked but no hardware HEVC/VideoToolbox encoder validation may execute on the affected Mac. Encoding failure stops canonical capture visibly and records a content-free diagnostic error.

Every indexed frame points to a chunk ID, logical presentation timestamp, and exact source HEIC path. A separate 480-pixel HEIC thumbnail is generated asynchronously.

## Activity signals

CGEventTap records only event class (`click`, `scroll`, or `keyActivity`) and monotonic timestamp. It never records key codes, characters, clipboard contents, cursor path, or application payload. These signals control idle state and accelerate acceptance after interaction.

## Context and browser policy

ContextMonitor maintains foreground bundle ID/name, focused-window identity/title/frame, approved browser origin/title/private state, lock state, and secure-input state.

Adapters are fixture-tested for Safari, Chrome, Arc/Dia-family Chromium, Edge, and Firefox. Browser URL context must correspond to the resolved target window. If that association is not reliable while any site exclusion exists, suppress that browser window until context returns or all site exclusions are removed.

## Privacy sequence

Non-removable exclusions are the app's own bundle, login/lock-screen processes, and system permission surfaces. Detected password managers start in an editable exclusion set. Private browser windows are excluded by default.

Before applying a content filter:

1. Recording is active, screen unlocked, and secure input inactive.
2. A unique eligible foreground `SCWindow` resolves on the main display.
3. Owning application and window are allowed.
4. Private/browser origin/path policy is allowed.

Immediately before media append, repeat those checks and require the same epoch and target identity. Any uncertainty produces no pixels. Because the filter contains only the approved window, background sensitive content is structurally outside the captured surface.

## Permission onboarding

1. Explain and request Screen Recording after user action.
2. Verify a real single-window sample that visibly omits the desktop/background.
3. Explain and request Accessibility.
4. Verify focused-window identity and text extraction.
5. Offer launch at login only after capture works.
6. Never request microphone/system audio during visual onboarding.

Permission status comes from capability probes, not button clicks. Keep a fixed bundle identifier and stable signing identity so TCC survives rebuilds.

## Backpressure, lifecycle, and failure behavior

`CaptureLifecycleCoordinator` is the single fail-closed projection between capture inputs,
the menu/settings UI, and `activity_intervals`. It admits capture only when recording is
enabled, the process/archive/storage/filter are healthy, Screen Recording permission is
granted, activity is neither idle nor suspended, and one approved target window exactly
matches the running stream. Every other combination clears the active target before it
projects a visible cause. The visible projection budget is 250 ms.

The canonical timeline mapping remains intentionally small: user pause, idle, permission
loss, filter failure, sleep/session lock, and each resolver failure retain their exact
`RecordingGapReason`; low disk, archive failure, and process interruption are the three
exact visible stop causes within the canonical `processStopped` timeline class. No lifecycle
gap stores application identity. A previously recording/indexing persisted state always
relaunches as `processStopped`, restores the gap from the last persisted lifecycle timestamp,
and must reconcile every current input before capture resumes.

Launch at login is opt-in. Reading `SMAppService.mainApp.status` never registers the service.
Only the user's Settings toggle may call `register()`/`unregister()`. A
`requiresApproval` result displays the H3 Login Items action and does not imply success.

- Capture-to-media queue capacity 4; drop redundant heartbeats first.
- Never block SCStream callbacks on database/model work.
- Derived jobs persist in SQLite without retaining pixels.
- Defer MobileCLIP/accurate OCR under serious thermal state or low battery.
- On focus change, revoke epoch before updating the filter.
- On resize, end the fixed-dimension chunk and begin a new epoch/configuration.
- On sleep/session lock, finish/abandon the chunk and revoke target.
- On wake, refresh shareable content and resume within 30 seconds if eligible.
- On permission loss, disk full, filter failure, or database failure, stop visibly.
- On crash, remove partials, reconcile ready chunks, and resume jobs.

## Milestones and gates

### C1 Window resolver

Gate: 500 focus transitions across fixture apps resolve the correct `SCWindow`; every ambiguous case emits no pixels.

### C2 Epoch-safe stream

Gate: rapid focus/URL/window/resize changes never persist a buffer from a prior epoch and begin the approved new target within one second p95.

### C3 Hardware media

Gate: eight-hour foreground-window fixture encodes with hardware acceleration, playable fixed-dimension chunks, bounded storage, and random extraction below target.

### C4 Pixel-contamination privacy

Place uniquely colored/encoded sentinel grids in background, excluded, notification-like, split-screen-adjacent, and private-browser windows. Gate: automated pixel/OCR/hash scans find zero sentinel content in media, thumbnails, OCR, AX projections, vectors, caches, or logs.

## Verification

- PID/geometry/title window-resolver fixtures, including duplicate titles
- Rapid filter-update/stale-buffer race tests
- Background password-manager, notification, private-tab, and split-screen sentinels
- Browser URL-to-target-window association fixtures
- Window minimize/close/resize/secondary-display transitions
- Eight-hour foreground soak and repeated sleep/wake
- Kill during filter update, frame staging, manifest finalization, directory rename, and DB commit
- Instruments energy, CPU, memory, Image I/O, and WindowServer attribution

## Sources

- [Apple ScreenCaptureKit](https://developer.apple.com/documentation/ScreenCaptureKit)
- [SCContentFilter single-window capture](https://developer.apple.com/documentation/screencapturekit/sccontentfilter/init%28desktopindependentwindow%3A%29)
- [SCStream filter updates](https://developer.apple.com/documentation/screencapturekit/scstream)
- [SCWindow identity and owning application](https://developer.apple.com/documentation/screencapturekit/scwindow)
- [AXUIElement process identity](https://developer.apple.com/documentation/applicationservices/1459374-axuielementcreateapplication)
- [AX window/top-level attributes](https://developer.apple.com/documentation/applicationservices/kaxwindowattribute)
- [Apple Image I/O](https://developer.apple.com/documentation/imageio)
- [Uniform Type Identifiers HEIC](https://developer.apple.com/documentation/uniformtypeidentifiers/uttype-swift.struct/heic)
