#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-022"
test_log=${1:-"$result_root/privacy-policy-tests.txt"}
matrix_output=${2:-"$result_root/privacy-policy.json"}
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
  -only-testing:LocalMemoryUnitTests/PrivacyPolicyTests \
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
  --lm022-export-privacy-policy "$matrix_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 11 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$matrix_output"
jq -e '
  .schemaVersion == 1 and
  .fixtureCount == 1000 and
  .exactDecisionCount == 1000 and
  .deniedCount == 1000 and
  .reasonCounts == {
    "ambiguousTarget": 200,
    "browserContextUnavailable": 200,
    "missingTarget": 200,
    "privateBrowserDefault": 200,
    "userRule": 200
  } and
  .backgroundSentinelSceneCount == 1000 and
  .persistedPixelPayloadCount == 0 and
  .persistedTextPayloadCount == 0 and
  .persistedDerivedArtifactCount == 0 and
  .persistedCachePayloadCount == 0 and
  .auditRowCount == 1000 and
  .auditContentFieldCount == 0 and
  .deniedAuditContextFieldCount == 0 and
  .fixedExclusionCount >= 4 and
  .fixedExclusionOverrideCount == 0 and
  (.passwordManagerDefaultsVersion | length) > 0 and
  .passwordManagerDefaultsEditable == true and
  .privateBrowserDefaultEditable == true and
  .finalTargetRecheckPassed == true and
  .finalEpochRecheckPassed == true and
  .finalPolicyGenerationRecheckPassed == true and
  ([.records[] | select(.projectedArtifactCount != 0 or .auditContentFieldCount != 0)] | length) == 0 and
  .allInvariantsPassed == true
' "$matrix_output" >/dev/null

if rg -n 'LM022_PROHIBITED_CONTENT_SENTINEL|windowTitle|serializedURL|textPayload|pixelPayload' \
  "$matrix_output"
then
  echo "Content-bearing field leaked into LM-022 evidence" >&2
  exit 1
fi

echo "LM-022 compiled privacy policy gate passed"
