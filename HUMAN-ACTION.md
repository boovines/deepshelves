# H9 human action

- **Blocking story and reason:** LM-048 and all dependency-safe implementation through LM-080
  are code-complete, but the unchanged installed application, accessibility, capture, and media
  criteria require the physically distinct H9 validation Mac before LM-081 may begin.
- **One concrete action:** On a physically distinct, recoverable validation Mac, clone the
  private `deepshelves` repository, check out
  `checkpoints/H9-visual-redesign-blocked-human`, install the pinned Xcode/toolchain, grant only
  Screen Recording and Accessibility to the fixed Local Memory bundle there, then return to
  this goal from that Mac and reply `done`.
- **What to expect:** The checkout contains
  `Docs/Operations/H9-isolated-runtime-validation.md` and the ordered 20-item ledger template.
  After `done`, Codex will verify the host, revision, toolchain, permissions, and clean process
  state before running that ledger once under deny-all networking and the encoder-service
  tripwire.
- **What must not be approved or changed:** Do not grant permissions, launch Local Memory,
  run XCUITest, or run ScreenCaptureKit, ImageIO, VideoToolbox, HEVC, AVAssetWriter, or any
  media path on this laptop. On the validation Mac, do not approve microphone, automation,
  Full Disk Access, network access, or any permission beyond the two documented grants.
- **Resume probe:** Verify a physically distinct host by its one-way hardware identity; verify
  the private checkout resolves exactly to
  `checkpoints/H9-visual-redesign-blocked-human`, the pinned Xcode/dependencies and only the
  documented Screen Recording/Accessibility grants are present, and no `xcodebuild`, `xctest`,
  `VTEncoderXPCService`, product, watcher, or hardware-media process is running; then initialize
  and execute H9-001 through H9-020 in order.
