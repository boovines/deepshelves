# H9 isolated runtime validation

## Blocking story and reason

LM-064 is blocked because the complete ADR-0006 runtime ledger must run on a physically
distinct, recoverable Mac. Application, ScreenCaptureKit, ImageIO, VideoToolbox, and media
runtime remain prohibited on the owner's current laptop, and no static/compile result may
substitute for this evidence.

## One action

On a physically distinct, recoverable Mac, clone the private `boovines/deepshelves`
repository, check out `checkpoints/LM-064-h9`, open this same Codex goal from that checkout,
grant only Screen Recording and Accessibility to the fixed Local Memory app when macOS asks,
and then reply `done` in this goal thread.

## What to expect

The isolated Mac should show the repository at the H9 checkpoint with Xcode 26.5
(`17F42`) available. During resumed validation, macOS may show Screen Recording,
Accessibility, UI Automation, and the already documented development-signing/Keychain
prompts for Local Memory. The ordered ledger will stop immediately if a hardware media
service appears and will retain only content-free failure diagnostics.

## Do not approve or change

Do not perform this action on the owner's current Mac. Do not grant Microphone, Full Disk
Access, network exceptions, or any permission not named above. Do not change the revision,
toolchain, privacy rules, foreground-window-only capture, dependency pins, sandbox-denial
policy, or encoder-service tripwire. Do not manually continue after a tripwire stop.

## Resume probe

Before any runtime action, the agent will hash `IOPlatformUUID` and require it to differ from
the owner-laptop hash embedded in `scripts/run-lm063-offline-gate.sh`; require `HEAD` to equal
`checkpoints/LM-064-h9`; verify `xcodebuild -version`; verify no `xcodebuild`, `xctest`, or
`VTEncoderXPCService` process exists; and only then run the documented H9 capability and
permission probes on the isolated Mac.
