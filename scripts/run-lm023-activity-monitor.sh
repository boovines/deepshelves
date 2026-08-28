#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-023"
test_log=${1:-"$result_root/activity-monitor-tests.txt"}
report_output=${2:-"$result_root/activity-monitor.json"}
app_stdout="$result_root/app.stdout.txt"
app_stderr="$result_root/app.stderr.txt"
derived_data="$repo_root/.build/SignedDerivedData"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"
app_binary="$app_bundle/Contents/MacOS/Local Memory"
activity_source="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/ActivityMonitor.swift"

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
  -only-testing:LocalMemoryUnitTests/ActivityMonitorTests \
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
open -W -n "$app_bundle" --args \
  --lm023-export-activity-monitor "$report_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 9 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$report_output"
jq -e '
  .schemaVersion == 1 and
  .activeWindowNanoseconds == 1000000000 and
  .idleThresholdNanoseconds == 300000000000 and
  .inputClasses == ["click", "scroll", "keyActivity"] and
  .lifecycleEvents == ["willSleep", "didWake", "sessionLocked", "sessionUnlocked"] and
  .stateTransitionCount == 15 and
  .exactStateTransitionCount == 15 and
  .ignoredSuspendedInputCount == 2 and
  .activitySignalStoredFieldNames == ["inputClass", "monotonicNanoseconds"] and
  .sensitiveInputPayloadFieldCount == 0 and
  .idleAcceptanceRejected == true and
  .activityRecoveryPassed == true and
  .targetChangeRecoveryPassed == true and
  .allInvariantsPassed == true
' "$report_output" >/dev/null

source_forbidden='NSPasteboard|kCGKeyboardEventKeycode|CGEventKeyboardGetUnicodeString|keyCode|characters|clipboard|mouseLocation|CGEventGetIntegerValueField'
if rg -n "$source_forbidden" "$activity_source"; then
  echo "Sensitive input accessor or payload field found in ActivityMonitor source" >&2
  exit 1
fi

binary_payload_fields='raw(Key|Keyboard)(Payload|Value)|clipboard(Content|Payload|Value)|cursor(Path|Payload)'
if strings "$app_binary" | rg -i "$binary_payload_fields"; then
  echo "Sensitive input payload field embedded in signed application" >&2
  exit 1
fi

echo "LM-023 coarse activity and lifecycle gate passed"
