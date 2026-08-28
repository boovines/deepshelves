# LM-039 technical blocker — XCUITest runtime quarantine

## Safe work completed

- The root app owns one `SearchSessionModel` and injects that exact instance into the main Search section and global search panel.
- The model trims input, debounces for 150 ms, cancels superseded tasks, clears stale results immediately, rejects late results by generation, and settles each generation exactly once.
- Production request scope is derived only from fully ready frame, media, and approved merged-text records.
- Deterministic warm, slow, and content-free error XCUITest fixtures compile successfully.
- Fourteen focused Release unit tests prove warm state, slow loading, cancellation-resistant rapid typing, exactly-once ordering, content-free failure, query reset, and ready-only metadata scope.
- Contracts, privacy smoke, dependency audit, strict formatting, UI compile-only, and universal Release compile all pass under the 50 ms encoder-service tripwire.
- No application, XCUITest runtime, Apple ImageIO, AVAssetWriter, HEVC encoder, VideoToolbox, or `VTEncoderXPCService` execution occurred.

## Remaining acceptance gate

Run `SearchStateBindingUITests` against the signed Release application and pass the warm, slow, and error fixtures, including main/panel shared query state and absence of stale results during rapid typing.

This Mac cannot safely execute that gate. Application runtime remains quarantined after a prior launch correlated with unexpected `VTEncoderXPCService` activity, in the same environment where two hardware-video paths produced repeatable `dart-ave AppleT8110DART` kernel panics. Compile-only and source-isolated tests cannot truthfully substitute for the required XCUITest runtime assertion.

## Resume probe

On a known-safe validation Mac, first assert no `xcodebuild`, `xctest`, or `VTEncoderXPCService` process is active. Run only `SearchStateBindingUITests` from the `LocalMemory-UI` scheme under the 50 ms encoder-service tripwire. Abort immediately if `VTEncoderXPCService` appears. Do not run ImageIO, AVAssetWriter, hardware HEVC, or VideoToolbox probes. If all three fixtures pass without the service appearing, attach the `.xcresult`, update `Results/LM-039/report.json`, and change LM-039 from `blocked` to `passed`.
