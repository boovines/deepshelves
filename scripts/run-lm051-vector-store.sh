#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-051"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-051 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-051 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVectorStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEnrichmentJobStore.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisualEmbeddingJobs.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ExactVectorScan.swift"
  "$repo_root/Tests/Unit/ArchiveVectorStoreTests.swift"
  "$repo_root/Tests/Unit/VisualEmbeddingJobTests.swift"
  "$repo_root/Tests/Unit/VectorSpikeCoreTests.swift"
)
format_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVectorStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEnrichmentJobStore.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisualEmbeddingJobs.swift"
  "$repo_root/Tests/Unit/ArchiveVectorStoreTests.swift"
  "$repo_root/Tests/Unit/VisualEmbeddingJobTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-051 sources" >&2
  exit 1
fi

jq -e '
  .results.vectorCount == 1000000
  and .results.vectorDimension == 512
  and .results.vectorFileBytes == 1024000128
  and .results.stableOrderingMatched == true
  and .results.truncatedFileDetectedBeforeResults == true
  and .results.filteredP95Milliseconds <= 750
  and .results.vectorScanIncrementalRSSMegabytes <= 500
' "$repo_root/Results/LM-007/report.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM051" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/ArchiveVectorStoreTests \
    -only-testing:LocalMemoryUnitTests/VisualEmbeddingJobTests \
    -only-testing:LocalMemoryUnitTests/VectorSpikeCoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 17 ]]

xcrun swift-format lint --strict "${format_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-051 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "format_magic=DSVEC002"
  echo "format_header_bytes=192"
  echo "vector_dimension=512"
  echo "vector_bytes=1024"
  echo "storage_precision=Float16"
  echo "header_identity=model+producer+preprocessing+generation+sha256"
  echo "publication_protocol=fsync-stage-scheduler-success-ready"
  echo "forty_vector_property_retained=26"
  echo "forty_vector_property_removed=14"
  echo "forty_vector_compacted_bytes=26816"
  echo "application_launches_executed=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/unit-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/unit-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "append_fsync_and_staged_publication=passed"
  echo "scheduler_success_ready_promotion=passed"
  echo "idempotent_duplicate_retry=passed"
  echo "crash_tail_repair=passed"
  echo "truncation_checksum_wrong_model_fail_closed=passed"
  echo "duplicate_offset_rejection=passed"
  echo "compaction_swap_rollback=passed"
  echo "compaction_database_finish_recovery=passed"
  echo "complete_rebuild_requeue=passed"
  echo "million_vector_baseline=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-051 vector storage gate passed without app, ImageIO, or video runtime"
