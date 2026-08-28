#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-024"
test_log=${1:-"$result_root/epoch-capture-tests.txt"}
report_output=${2:-"$result_root/epoch-capture.json"}
app_stdout="$result_root/app.stdout.txt"
app_stderr="$result_root/app.stderr.txt"
derived_data="$repo_root/.build/SignedDerivedData"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"
app_binary="$app_bundle/Contents/MacOS/Local Memory"
epoch_source="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/EpochCapturePipeline.swift"
binary_strings=$(mktemp "${TMPDIR:-/tmp}/deepshelves-lm024-strings.XXXXXX")
trap 'rm -f "$binary_strings"' EXIT

mkdir -p "$result_root"
"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null

xcodebuild \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemory \
  -configuration Debug \
  -derivedDataPath "$repo_root/.build/DerivedData" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalMemoryUnitTests/WindowCaptureEpochTests \
  test 2>&1 | tee "$test_log"

xcodebuild -quiet \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemoryApp \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  -allowProvisioningUpdates \
  build

codesign --verify --deep --strict "$app_bundle"
"$app_binary" \
  --lm024-export-epoch-capture "$report_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 10 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$report_output"
jq -e '
  .schemaVersion == 1 and
  .rapidRaceCount == 50 and
  .exactRaceCount == 50 and
  .raceCategoryCounts == {"filter": 13, "focus": 13, "resize": 12, "url": 12} and
  .staleFrameAcceptedCount == 0 and
  .currentFrameAcceptedCount == 50 and
  .epochCount == 50 and
  .filterApplicationCount == 50 and
  .transitionLatencyP95Nanoseconds < 1000000000 and
  .transitionsWithinOneSecondCount == 50 and
  .nearDuplicateSequenceCount == 50 and
  .nearDuplicateDeduplicatedCount == 50 and
  .visualChangeAcceptedCount == 50 and
  .luminanceGridSampleCount == 4096 and
  .visualDifferenceThreshold == 2 and
  .mediaQueueCapacity == 4 and
  .mediaQueuePeakCount == 4 and
  .staleQueueDropCount == 2 and
  .heartbeatQueueDropCount > 0 and
  .oldestQueueDropCount > 0 and
  .newestFrameRetained == true and
  .singleWindowFilterOnly == true and
  (.records | length) == 50 and
  ([.records[].currentAccepted] | all) and
  ([.records[].staleRejection] | all(. != "accepted")) and
  .allInvariantsPassed == true
' "$report_output" >/dev/null

test "$(rg -c 'SCContentFilter\(desktopIndependentWindow:' "$epoch_source")" -ge 1
if rg -n 'SCContentFilter\((display:|excludingWindows:|includingApplications:)' "$epoch_source"; then
  echo "Non-window ScreenCaptureKit filter construction found in epoch pipeline" >&2
  exit 1
fi
strings "$app_binary" >"$binary_strings"
rg -q 'ScreenCaptureKitEpochStream' "$binary_strings"

echo "LM-024 epoch race, measured deduplication, and backpressure gate passed"
