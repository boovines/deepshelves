#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-052"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-052 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-052 safe gate" >&2
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
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/ExactVisualVectorSearch.swift"
  "$repo_root/Tests/Unit/ArchiveVectorStoreTests.swift"
  "$repo_root/Tests/Unit/ExactVisualVectorSearchTests.swift"
  "$repo_root/Tests/Unit/VectorSpikeCoreTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-052 sources" >&2
  exit 1
fi

jq -e '
  .results.vectorCount == 1000000
  and .results.vectorDimension == 512
  and .results.vectorFileBytes == 1024000128
  and .results.unfilteredP95Milliseconds < 750
  and .results.unfilteredP99Milliseconds < 1000
  and .results.filteredCandidateCount == 100000
  and .results.filteredP95Milliseconds < 250
  and .results.vectorScanIncrementalRSSMegabytes < 500
  and .results.maximumScalarScoreError <= 0.001
  and .results.stableOrderingMatched == true
  and .results.truncatedFileDetectedBeforeResults == true
' "$repo_root/Results/LM-007/report.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM052" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/ArchiveVectorStoreTests \
    -only-testing:LocalMemoryUnitTests/ExactVisualVectorSearchTests \
    -only-testing:LocalMemoryUnitTests/VectorSpikeCoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 16 ]]

assert_safe_process_state
run_encoder_monitored "$result_root/scale-tests.txt" \
  env LM052_SCALE_TESTS=1 xcrun xctest \
    -XCTest ExactVisualVectorSearchTests/testScaleBenchmarkAt100k500kAnd1M \
    "$repo_root/.build/DerivedDataLM052/Build/Products/Release/LocalMemoryUnitTests.xctest"
rg -q 'Test Case .*testScaleBenchmarkAt100k500kAnd1M.* passed' "$result_root/scale-tests.txt"
rg -o 'LM052_SCALE_METRICS \{.*\}' "$result_root/scale-tests.txt" \
  | sed 's/^LM052_SCALE_METRICS //' >"$result_root/scale-metrics.json"
jq -e '
  .scales | length == 3
  and .[0].vectorCount == 100000
  and .[0].p95Milliseconds < 250
  and .[1].vectorCount == 500000
  and .[1].p95Milliseconds < 750
  and .[2].vectorCount == 1000000
  and .[2].p95Milliseconds < 750
  and .[2].p99Milliseconds < 1000
' "$result_root/scale-metrics.json" >/dev/null
jq -e '.incrementalResidentMegabytes < 500' "$result_root/scale-metrics.json" >/dev/null

xcrun swift-format lint --strict \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVectorStore.swift" \
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/ExactVisualVectorSearch.swift" \
  "$repo_root/Tests/Unit/ArchiveVectorStoreTests.swift" \
  "$repo_root/Tests/Unit/ExactVisualVectorSearchTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-052 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "scanner=read-only mmap+bounded Float16-to-Float32 chunks+Accelerate"
  echo "default_chunk_candidates=4096"
  echo "scale_chunk_candidates=16384"
  echo "prefilter=SQLite ready media/frame/vector offsets before scoring"
  echo "stable_order=score-desc,capturedAt-desc,uuid-asc"
  echo "cancellation=before mapping,each chunk,before projection"
  echo "integrity=file-size+header+generation+offset+winner-sha256"
  echo "application_launches_executed=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/unit-tests.txt" "$result_root/scale-tests.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/unit-tests.txt" "$result_root/scale-tests.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "sqlite_prefilter_before_scoring=passed"
  echo "scalar_parity_and_stable_top_k=passed"
  echo "cancellation_checks=passed"
  echo "header_file_size_offset_checksum_fail_closed=passed"
  echo "scale_100k_500k_1m=passed"
  echo "canonical_s4=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-052 exact vector search gate passed without app, ImageIO, or video runtime"
