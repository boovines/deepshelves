#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-021"
test_log=${1:-"$result_root/browser-context-tests.txt"}
matrix_output=${2:-"$result_root/browser-context.json"}
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
  -only-testing:LocalMemoryUnitTests/BrowserContextAdapterTests \
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
  --lm021-export-browser-context "$matrix_output" \
  >"$app_stdout" 2>"$app_stderr"

rg -q 'Executed 7 tests, with 0 failures' "$test_log"
test ! -s "$app_stderr"
test -s "$matrix_output"
jq -e '
  .schemaVersion == 1 and
  .supportedBrowsers == ["safari", "chrome", "arcDia", "edge", "firefox"] and
  .contextCount == 600 and
  .exactResolutionCount == 600 and
  .exactAccuracy >= 0.98 and
  .approvedCount == 480 and
  .privateCount == 30 and
  .unavailableCounts == {
    "ambiguousAddressField": 15,
    "privateStateUnavailable": 15,
    "targetWindowMismatch": 30,
    "unsupportedURL": 15,
    "urlUnavailable": 15
  } and
  .uniqueTargetAssociationCount == 510 and
  .sanitizedApprovedSerializationCount == 480 and
  .privateContentFieldCount == 0 and
  .addressFieldOnly == true and
  .publicAccessibilityOnly == true and
  .inspectedDOMOrNetworkTraffic == false and
  ([.records[] | select(.actual | startswith("approved:"))] | length) == 480 and
  ([.records[] | select(.actual | startswith("privateContext:")) | .approvedHost] | all(. == null)) and
  ([.records[] | select(.actual | startswith("privateContext:")) | .serializedURL] | all(. == null)) and
  .allInvariantsPassed == true
' "$matrix_output" >/dev/null

if rg -n 'credential-sentinel|query-sentinel|fragment-sentinel|SENSITIVE_PRIVATE' \
  "$matrix_output"
then
  echo "Sensitive URL or private-context component serialized in LM-021 evidence" >&2
  exit 1
fi

if rg -n '_AX|URLSession|WKWebView|WebKit|JavaScript|CGWindowListCreateImage|History\.db|Cookies\.sqlite' \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/BrowserContextAdapters.swift" \
  "$repo_root/Apps/LocalMemoryApp/LM021BrowserContextHarness.swift"
then
  echo "Private API, network, DOM, or browser-database access found in LM-021 path" >&2
  exit 1
fi

echo "LM-021 browser context matrix gate passed"
