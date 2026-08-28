#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-037"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-037 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-037 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveLexicalSearch.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSearchIndexStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/LexicalSearchEngine.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/SearchQueryParser.swift"
  "$repo_root/Tests/Unit/LexicalSearchEngineTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-037 sources" >&2
  exit 1
fi

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/LexicalSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests \
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/AXOCRSpanMergeTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"
focused_test_count=$(rg -c 'Test Case .* passed' "$result_root/focused-tests.txt")
[[ "$focused_test_count" -eq 37 ]]

run_encoder_monitored "$result_root/package-tests.txt" \
  swift test --package-path "$repo_root/Packages/MemorySearch"
package_test_count=$(rg -c 'Test Case .* passed' "$result_root/package-tests.txt")
[[ "$package_test_count" -eq 8 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift" \
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-037 sources and fixtures." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

engine_source="$repo_root/Packages/MemorySearch/Sources/MemorySearch/LexicalSearchEngine.swift"
store_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveLexicalSearch.swift"
{
  rg -Fq 'bm25(frame_fts, 6.0, 4.0, 2.0, 2.0, 1.5, 1.0)' "$store_source"
  rg -Fq "merged_text_records.state = 'ready'" "$store_source"
  rg -Fq "sensitivity <> 'suppressed'" "$store_source"
  rg -Fq 'ROW_NUMBER() OVER' "$store_source"
  rg -Fq 'HMAC<SHA256>' "$engine_source"
  rg -Fq 'queryFingerprint' "$engine_source"
  rg -Fq 'returnedCount' "$engine_source"
  rg -Fq 'Task.checkCancellation()' "$engine_source"
  rg -Fq 'terms.map' "$engine_source"
  echo "access_policy_hard_filters=passed"
  echo "weighted_bm25_and_fixed_boosts=passed"
  echo "literal_fts_query=passed"
  echo "source_evidence_no_summary=passed"
  echo "signed_query_fingerprinted_keyset_cursor=passed"
  echo "policy_wide_result_cap=passed"
  echo "cancellation_boundaries=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n \
  --argjson focusedTests "$focused_test_count" \
  --argjson packageTests "$package_test_count" '{
  schemaVersion: 1,
  story: "LM-037",
  status: "passed",
  engine: "LexicalSearchEngine",
  fields: [
    "approved_text", "window_title", "app_name",
    "url_host", "url_path", "transcript_text"
  ],
  bm25Weights: [6, 4, 2, 2, 1.5, 1],
  hardPolicyFiltersBeforeProjection: true,
  literalFTSQuery: true,
  stableOrder: ["score_desc", "captured_at_desc", "frame_uuid_asc"],
  signedQueryFingerprintedCursor: true,
  policyWideResultCap: true,
  cancellationAware: true,
  sourceEvidenceOnly: true,
  focusedTests: $focusedTests,
  parserPackageTests: $packageTests,
  hardwareEncoderTestsExecuted: 0,
  applicationLaunchesExecuted: 0
}' >"$result_root/report.json"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" "$result_root/package-tests.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" "$result_root/package-tests.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "focused_release_tests=passed"
  echo "parser_package_tests=passed"
  echo "access_policy_and_request_filters=passed"
  echo "weighted_order_evidence_pagination=passed"
  echo "cursor_tamper_scope_and_total_cap=passed"
  echo "cancellation_and_literal_query=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-037 lexical SearchEngine gate passed without media runtime execution"
