#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-019"
test_log=${1:-"$result_root/lifecycle-tests.txt"}
lifecycle_output=${2:-"$result_root/lifecycle.json"}
app_stdout="$result_root/app.stdout.txt"
app_stderr="$result_root/app.stderr.txt"
derived_data="$repo_root/.build/SignedDerivedData"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"

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
  -only-testing:LocalMemoryUnitTests/ScreenCaptureRuntimeTests \
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
  --lm019-export-lifecycle "$lifecycle_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 9 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$lifecycle_output"
jq -e '
  .schemaVersion == 1 and
  .permission == "granted" and
  .initialState == "stoppedNoEligibleTarget" and
  .initialFramesDelivered == 0 and
  .initialRefreshStatus == "available" and
  (.firstRunningState | startswith("running:")) and
  .framesBeforeDisplayRestart > 0 and
  .framesAfterDisplayRestart > .framesBeforeDisplayRestart and
  .finalState == "stoppedNoEligibleTarget" and
  .deliveredSurfaceKinds == ["foregroundWindow"] and
  .compositedDisplayFramesDelivered == 0 and
  .framesPersisted == 0 and
  .pixelBufferLeasesReleased == .framesAfterDisplayRestart and
  .allInvariantsPassed == true
' "$lifecycle_output" >/dev/null

if rg -n 'SCContentFilter\((display|excluding|including)' \
  "$repo_root/Packages/MemoryCapture/Sources" \
  "$repo_root/Apps/LocalMemoryApp"
then
  echo "Forbidden composited-display ScreenCaptureKit filter construction found" >&2
  exit 1
fi
rg -q 'SCContentFilter\(desktopIndependentWindow:' \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureSpikeRunner.swift"
rg -q 'SCContentFilter\(desktopIndependentWindow:' \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/ScreenCaptureRuntime.swift"

echo "LM-019 fake/real foreground-window lifecycle gate passed"
