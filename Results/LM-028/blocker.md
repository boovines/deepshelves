# LM-028 technical blocker

## Minimal reproduction

On 2026-08-28, after confirming no `xcodebuild`, `xctest`, or
`VTEncoderXPCService` process existed, a metadata-only `sips -g pixelWidth -g pixelHeight`
probe read pinned libheif HEIC fixtures. `VTEncoderXPCService` then appeared with parent PID
1. The tripwire found it, recorded its process state, and terminated it. No kernel panic was
observed. The command is documented here and must not be rerun on this Mac.

## Suspected layer

Apple ImageIO/HEIC dispatch can initialize VideoToolbox even for a seemingly decode-only
metadata path. `CIContext(useSoftwareRenderer: true)` controls Core Image rendering but does
not prove that `CGImageDestination` or `CGImageSource` avoids VideoToolbox.

## Safe work completed

- Removed implicit construction of `ImageIOHEICFrameEncoder`.
- Made legacy capture and decode harnesses fail closed.
- Kept production ImageIO code compile-only.
- Ran 67 safe focused Release tests through fakes and non-codec seams.
- Ran the exact-frame corpus only through FFmpeg software HEVC with `-hwaccel none` and a
  `VTEncoderXPCService` tripwire.
- Completed synthetic eight-hour/72-hour queue, privacy, recovery, and storage models.

## Fixed invariants

No foreground-window, local-only, privacy identity, atomic publication, integrity, search
evidence, retention, or forensic-deletion invariant needs to change. The HEIC manifest and
independent-frame representation remain accepted.

## Exact remaining gate

A real eight-hour run must exercise the same encoder and decoder that the shipping app will
use while measuring CPU, memory, storage, corruption, recovery, and pixel contamination.
No currently authorized runtime on this Mac can prove that without risking the quarantined
VideoToolbox path. LM-028 therefore remains `blocked`, not `passed` and not `blocked_human`.

## 2026-08-29 headless runtime falsification

After ADR 0001 adopted the pinned software-only HEIC helper, a narrow command-line harness
was built to determine whether the real foreground-window ScreenCaptureKit source could run
without launching Local Memory. Static linkage showed no direct ImageIO, VideoToolbox,
MediaToolbox, or AVFoundation framework dependency, and a permission-only preflight passed.

One five-second smoke attempt then exited with the content-free error
`capture_or_decode_failed`. The command itself was gone, but a parentless
`VTEncoderXPCService` (PID 70643, PPID 1) remained. It was observed after 78 seconds of
elapsed service time and terminated immediately. No second live attempt was made.

This falsifies the claim that the live ScreenCaptureKit path is encoder-service-free on this
Mac; it does not implicate the pinned libheif/x265 codec itself and it does not weaken the
accepted HEIC design. The uncommitted runnable harness, its SwiftPM target, and its generated
binary were removed so the unsafe experiment cannot be repeated accidentally. The exact
remaining gate is still a real eight-hour production capture soak on a validation environment
where the complete live source plus software codec is proven not to start VideoToolbox.
