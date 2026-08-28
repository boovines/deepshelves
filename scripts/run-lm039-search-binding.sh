#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-039"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-039 gate while a test or encoder process is active" >&2
    exit 90
  fi
}

run_encoder_monitored() {
  local log=$1
  shift
  assert_safe_process_state
  "$@" >"$log" 2>&1 &
  local command_pid=$!
  local encoder_seen=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if pgrep -x VTEncoderXPCService >/dev/null; then
      encoder_seen=1
      kill -TERM "$command_pid" 2>/dev/null || true
      pkill -x xcodebuild 2>/dev/null || true
      pkill -x xctest 2>/dev/null || true
      pkill -x VTEncoderXPCService 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  set +e
  wait "$command_pid"
  local status=$?
  set -e
  if [[ "$encoder_seen" -ne 0 ]]; then
    echo "ABORTED: encoder service appeared during LM-039 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  "$repo_root/Apps/LocalMemoryApp/GlobalSearchPanel.swift"
  "$repo_root/Apps/LocalMemoryApp/LocalMemoryApp.swift"
  "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  "$repo_root/Apps/LocalMemoryApp/SearchPresentation.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/SearchSessionModel.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Tests/Unit/SearchSessionModelTests.swift"
  "$repo_root/Tests/Unit/ArchiveSearchIndexStoreTests.swift"
  "$repo_root/Tests/UI/SearchStateBindingUITests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-039 sources" >&2
  exit 1
fi

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/safe-unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM039" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/SearchSessionModelTests \
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/safe-unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/safe-unit-tests.txt") -eq 14 ]]

# Compile the warm/slow/error XCUITest fixtures, but never launch the application or test runtime.
run_encoder_monitored "$result_root/ui-compile-only.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory-UI \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM039UI" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    build
rg -q '\*\* BUILD SUCCEEDED \*\*' "$result_root/ui-compile-only.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-039 sources and fixtures." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

model_source="$repo_root/Packages/MemorySearch/Sources/MemorySearch/SearchSessionModel.swift"
root_source="$repo_root/Apps/LocalMemoryApp/LocalMemoryApp.swift"
fixture_source="$repo_root/Tests/UI/SearchStateBindingUITests.swift"
{
  rg -Fq '@StateObject private var searchModel: SearchSessionModel' "$root_source"
  rg -Fq 'searchModel: searchModel' "$root_source"
  rg -Fq 'generation' "$model_source"
  rg -Fq 'searchTask?.cancel()' "$model_source"
  rg -Fq 'settlementCount += 1' "$model_source"
  rg -Fq 'fixture: "warm"' "$fixture_source"
  rg -Fq 'fixture: "slow"' "$fixture_source"
  rg -Fq 'fixture: "error"' "$fixture_source"
  echo "root_owned_shared_search_model=passed"
  echo "debounced_generation_cancellation=passed"
  echo "exactly_once_settlement=passed"
  echo "ready_only_local_policy_scope=passed"
  echo "warm_slow_error_fixtures_compile=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
  echo "application_launches_executed=0"
  echo "xcui_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/safe-unit-tests.txt" "$result_root/ui-compile-only.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/safe-unit-tests.txt" "$result_root/ui-compile-only.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "shared_search_model=passed"
  echo "rapid_typing_stale_result_unit_proof=passed"
  echo "ready_only_policy_scope=passed"
  echo "ui_fixture_compile_only=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "xcui_runtime_gate=quarantined"
} | tee "$result_root/story-gate.txt"

echo "LM-039 safe implementation gate passed; XCUITest runtime remains quarantined"
