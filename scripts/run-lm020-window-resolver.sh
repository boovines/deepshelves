#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-020"
test_log=${1:-"$result_root/resolver-tests.txt"}
resolver_output=${2:-"$result_root/resolver.json"}
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
  -only-testing:LocalMemoryUnitTests/ForegroundWindowResolverTests \
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
  --lm020-export-resolver "$resolver_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 5 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$resolver_output"
jq -e '
  .schemaVersion == 1 and
  .publicAPIsOnly == true and
  .foregroundWindowOnly == true and
  .corpus.transitionCount == 500 and
  .corpus.approvedCount == 350 and
  .corpus.exactResolutionCount == 500 and
  .corpus.zeroPixelGapCount == 150 and
  .corpus.gapCounts == {
    "ambiguousWindow": 25,
    "minimizedWindow": 25,
    "noWindow": 25,
    "protectedSurface": 25,
    "unresolvedWindow": 25,
    "unsupportedDisplay": 25
  } and
  ([.corpus.records[] | select(.actual | startswith("gap:")) | .pixelPayloadCount] | all(. == 0)) and
  .realProbe.accessibilityTrusted == true and
  .realProbe.screenRecordingPermission == "granted" and
  .realProbe.monitorTransitionKind == "initial" and
  .realProbe.foregroundProcessID == .realProbe.axWindowProcessID and
  .realProbe.axRole == "AXWindow" and
  (.realProbe.axIdentitySource == "focusedWindow" or
    .realProbe.axIdentitySource == "focusedAndTopLevel" or
    .realProbe.axIdentitySource == "topLevelWindow") and
  .realProbe.axIdentityConfirmed == true and
  .realProbe.focusedAndTopLevelGeometryAgree == true and
  .realProbe.refreshStatus == "available" and
  (.realProbe.resolution | startswith("approved:")) and
  .realProbe.resolvedWindowProcessID == .realProbe.foregroundProcessID and
  .realProbe.resolvedMainDisplay == true and
  .realProbe.pixelPayloadCount == 0 and
  .allInvariantsPassed == true
' "$resolver_output" >/dev/null

if rg -n '_AX|CGWindowListCreateImage|SCContentFilter\((display|excluding|including)' \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/ForegroundWindowMonitor.swift" \
  "$repo_root/Apps/LocalMemoryApp/LM020WindowResolverHarness.swift"
then
  echo "Private or composited-display API found in LM-020 production path" >&2
  exit 1
fi

echo "LM-020 strict foreground window resolver gate passed"
