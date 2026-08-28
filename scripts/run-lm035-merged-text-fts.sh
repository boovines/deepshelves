#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-035"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-035 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-035 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -180 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV1.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV3.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSearchIndexStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift"
  "$repo_root/Tests/Unit/ArchiveSearchIndexStoreTests.swift"
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-035 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests \
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/AXOCRSpanMergeTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"
focused_test_count=$(rg -c 'Test Case .* passed' "$result_root/focused-tests.txt")
[[ "$focused_test_count" -eq 29 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-035 sources and fixtures." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

schema_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV3.swift"
store_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSearchIndexStore.swift"
startup_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift"
{
  rg -Fq "content='merged_text_records'" "$schema_source"
  rg -Fq 'transcript_text' "$schema_source"
  rg -Fq "VALUES ('delete', ?, ?, ?, ?, ?, ?, ?)" "$store_source"
  rg -Fq "VALUES('delete-all')" "$store_source"
  rg -Fq 'SELECT id FROM frame_fts_docsize' "$store_source"
  rg -Fq 'deleteFrameAndSearchEvidence' "$store_source"
  rg -Fq "merged_text_records.state = 'ready'" "$startup_source"
  ! rg -n 'CREATE TRIGGER.*merged_text|CREATE TRIGGER.*frame_fts' "$schema_source"
  echo "external_content_authority=merged_text_records"
  echo "explicit_insert_update_delete_rebuild=passed"
  echo "ready_frame_docsize_integrity=passed"
  echo "reserved_transcript_provenance=passed"
  echo "startup_quarantine_suppression=passed"
  echo "implicit_fts_triggers=0"
  echo "hardware_encoder_tests_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n --argjson focusedTests "$focused_test_count" '{
  schemaVersion: 1,
  story: "LM-035",
  status: "passed",
  databaseSchemaVersion: 3,
  serializedContractVersion: 2,
  externalContentTable: "merged_text_records",
  indexedFields: [
    "approved_text", "window_title", "app_name",
    "url_host", "url_path", "transcript_text"
  ],
  explicitTransactionalMaintenance: true,
  implicitFTSTriggers: 0,
  readyFrameDocsizeParity: true,
  atomicRollbackVerified: true,
  forensicFrameDeletionVerified: true,
  suppressedInputFailsClosed: true,
  focusedTests: $focusedTests,
  hardwareEncoderTestsExecuted: 0,
  applicationLaunchesExecuted: 0
}' >"$result_root/report.json"

perl -pi -e 's/[ \t]+$//' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "focused_release_tests=passed"
  echo "schema_v3_migration=passed"
  echo "insert_update_delete_rebuild_parity=passed"
  echo "mid_transaction_rollback=passed"
  echo "suppressed_input_and_stale_term_absence=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-035 merged-text external-content FTS gate passed without media runtime execution"
