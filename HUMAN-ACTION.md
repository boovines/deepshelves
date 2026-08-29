# H9 human action

- **Blocking story and reason:** LM-080 is safely code-complete, but it and the other
  ADR-0006 stories still require the unchanged installed/application/media runtime evidence.
  H9 is now the mandatory prerequisite before LM-081.
- **One concrete action:** On a physically distinct, recoverable validation Mac, clone the
  private `deepshelves` repository, check out `checkpoints/LM-080-blocked-human`, install the
  pinned Xcode/toolchain, grant only Screen Recording and Accessibility to the fixed Local
  Memory bundle there, then return to this goal from that Mac and reply `done`.
- **What to expect:** The repository contains
  `Docs/Operations/H9-isolated-runtime-validation.md` and an ordered 20-item ledger template.
  After `done`, Codex will verify the host/revision/toolchain/permissions and run that ledger
  once under deny-all networking and the encoder-service tripwire.
- **What must not be approved or changed:** Do not grant permissions, launch Local Memory,
  run XCUITest, or run ScreenCaptureKit, ImageIO, VideoToolbox, HEVC, or hardware-media paths
  on this laptop. Do not approve microphone, automation, Full Disk Access, network, or any
  permission beyond Screen Recording and Accessibility on the validation Mac.
- **Resume probe:** Verify the host is physically distinct by its one-way hardware identity,
  the private checkout resolves exactly to `checkpoints/LM-080-blocked-human`, the pinned
  Xcode/dependency state is present, only the two documented TCC grants exist, and no
  `xcodebuild`, `xctest`, `VTEncoderXPCService`, product, watcher, or hardware-media process
  is running; then initialize and execute H9-001 through H9-020 in order.
