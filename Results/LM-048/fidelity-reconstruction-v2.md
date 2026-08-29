# Visual-memory fidelity reconstruction v2

## Method

- Inspected all eight supplied reference captures and the three user-supplied before captures at original resolution.
- Used Tesseract TSV output to compare text baselines and bounding boxes for the before Settings and Search surfaces against the references.
- Sampled reference and rendered surface colors directly from pixels.
- Rebuilt and launched only the deterministic `--fixture-only` profile, then inspected Timeline, Search, General, Appearance, Capture, and Agents through their real accessibility trees and rendered windows.
- No ScreenCaptureKit, ImageIO, VideoToolbox, AVAssetWriter, XCUITest, or media-runtime validation was invoked.

## Measured corrections

| Feature | Reference evidence | Reconstructed fixture | Result |
| --- | ---: | ---: | --- |
| Settings sidebar surface | RGB 247/247/247 | RGB 248/248/250 | Matched near-white semantic sidebar |
| Settings sidebar share | 26.3% of window width | 25.0% of window width | Within 1.3 percentage points |
| Settings first-card left edge | 28.4% of window width | 27.8% of window width | Within 0.6 percentage points |
| Settings first-card top edge | 13.1% of window height | 13.7% of window height | Within 0.6 percentage points |
| Search composer width | 94.9% of reference width | 95.7% of fixture width | Within 0.8 percentage points |
| Search composer-to-filter gap | 18 reference pixels | 16 fixture points at captured scale | Same compact one-step rhythm |

The before Search surface placed its first heading around 31% of the window height because the intrinsic view was vertically centered. The reconstructed surface is top-anchored immediately below the compact navigation bar. The before Settings surface started with an extra product masthead and a large section title; the reconstruction uses the reference hierarchy of `Settings` plus a quiet current-section subtitle.

## Functional reconstruction

- Timeline is canvas-first, with previous/next moment controls at the edges, a lower-left timestamp, a persistent app-colored interval rail, draggable playhead, and zoom controls.
- Search uses one prominent composer row with an explicit functional route menu, an expanded grouped filter panel, time pills, site pills, application tiles, and a visual result grid.
- Fixture-only Search and Timeline use deterministic procedural foreground-window imagery. No proprietary image, icon, logo, text, or source asset is present.
- Settings uses a near-white sidebar, compact title bar, rounded grouped cards, quiet icon tiles, one azure accent, and content-specific sections.
- Storage uses visual grouped cards for usage, bounded lifecycle policy, and truthful database/media protection instead of a database-like form.
- Activity fixture data is populated. Its full accessibility table remains available to assistive technology but is no longer rendered as a second spreadsheet-like panel.

## Intentional differences

- Local Memory shows only the approved foreground-window frame, never a whole-desktop capture.
- There is no Coast name, logo, proprietary art, exact icon set, source code, or distinctive copy.
- Capture quality choices are omitted because this Mac cannot safely validate new media parameters.
- Agent clients and installation status are not claimed without real detection. Local policies remain explicitly time-, app/site-, count-, and expiry-bounded.
- Local-only behavior, no telemetry, 30-day retention, 20-GB cap, deletion correctness, and scoped agent access remain unchanged.

## Deferred evidence

This reconstruction is compile-, unit-, accessibility-tree-, and fixture-render verified. H9 remains the required isolated-Mac gate for real capture, media, runtime UI, and final interaction acceptance; none of those deferred criteria are represented as passed here.
