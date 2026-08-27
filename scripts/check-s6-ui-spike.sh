#!/bin/bash
set -euo pipefail

root="${1:?usage: check-s6-ui-spike.sh RESULTS_ROOT}"
report="$root/s6-report.json"
xcuitest="$root/s6-xcuitest.json"
summary="$root/xcresult-summary.json"
environment="$root/environment.json"

for artifact in "$report" "$xcuitest" "$summary" "$environment" \
    "$root/s6-ui.png" "$root/xcodebuild.log" "$root/signatures.txt"; do
    [[ -s "$artifact" ]]
done

jq -e '
  .schemaVersion == 1 and
  .configuration == "Release" and
  .fixtureCardCount == 10000 and
  .timelineHours == 24 and
  .timelineMarkerCount == 96 and
  .initialResultCount == 60 and
  .searchFieldFocused == true and
  .coldPanelVisibleAndFocusedMilliseconds < 400 and
  .warmPanelVisibleAndFocusedMilliseconds < 150 and
  .initialRenderP95Milliseconds < 200 and
  .fastScrollFramesPerSecondP95 >= 55 and
  .maximumResidentMemoryMegabytes < 750 and
  .thumbnailFeedbackP95Milliseconds < 50 and
  .fullFrameSettleP95Milliseconds < 200 and
  .rapidSelectionCount == 100 and
  .staleScreenshotCount == 0 and
  .publishedSelectionID == .expectedSelectionID and
  .actorDecodeCacheCapacity == 96 and
  .windowResizePassed == true and
  .lightModePassed == true and
  .darkModePassed == true and
  .voiceOverProjectionPassed == true and
  .pseudoLocalizationPassed == true
' "$report" >/dev/null

jq -e '
  .schemaVersion == 1 and
  .releaseConfiguration == true and
  .rootExposed == true and
  .searchFieldExposed == true and
  .cardExposed == true and
  .timelineExposed == true and
  .lightDarkSwitchPassed == true and
  .pseudoLocalizationPassed == true and
  .windowResizePassed == true and
  .criticalControlsUnclipped == true and
  .voiceOverNavigationProjectionPassed == true
' "$xcuitest" >/dev/null

jq -e '
  .result == "Passed" and
  .totalTestCount == 1 and
  .passedTests == 1 and
  .failedTests == 0 and
  .skippedTests == 0 and
  all(.devicesAndConfigurations[];
    .device.platform == "macOS" and
    .device.architecture == "arm64" and
    .passedTests == 1 and
    .failedTests == 0)
' "$summary" >/dev/null

jq -e '
  .configuration == "Release" and
  .onlyActiveArchitecture == true and
  .uiFramework == "SwiftUI composition with NSCollectionView hot collection" and
  .signedApplication == true and
  .signedXCUITestRunner == true and
  (.mediaFixtureSHA256 | test("^[0-9a-f]{64}$")) and
  (.sourceManifestSHA256 | test("^[0-9a-f]{64}$"))
' "$environment" >/dev/null

file "$root/s6-ui.png" | rg -q 'PNG image data'
rg -q 'Authority=Apple Development:' "$root/signatures.txt"
rg -q '\*\* TEST SUCCEEDED \*\*' "$root/xcodebuild.log"

echo "S6 native UI, performance, decode, stale-selection, and accessibility gates passed: $root"
