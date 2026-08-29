#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-055"
derived_data="$repo_root/.build/DerivedDataLM055"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-055 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-055 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
  assert_safe_process_state
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/ExactVisualVectorSearch.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/HybridSearchEngine.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/VisualSearchEngine.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVectorStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSearchIndexStore.swift"
  "$repo_root/Tests/Unit/ExactVisualVectorSearchTests.swift"
  "$repo_root/Tests/Unit/HybridRetrievalBenchmarkTests.swift"
  "$repo_root/Tests/Unit/ArchiveVectorStoreTests.swift"
  "$repo_root/Tests/Unit/ArchiveSearchIndexStoreTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-055 sources" >&2
  exit 1
fi

fixture="$repo_root/Fixtures/LM038/retrieval-judgments.json"
fixture_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
[[ "$fixture_hash" == "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912" ]]
jq -e '
  (.frames | length) == 500
  and (.queries | length) == 100
  and ([.queries[] | select(.category == "visualSemantic")] | length) == 25
  and ([.queries[] | select((.judgments | length) < 3)] | length) == 0
' "$fixture" >/dev/null
jq -e '
  .results.visualRecallAt10 >= 0.80
  and .results.vectorCount == 1000000
  and .results.unfilteredP95Milliseconds < 750
  and .results.unfilteredP99Milliseconds < 1000
  and .results.vectorScanIncrementalRSSMegabytes < 500
' "$repo_root/Results/LM-007/report.json" >/dev/null
jq -e '
  .frozenJudgments.pipelineRecallAt10 >= 0.80
  and .frozenJudgments.forbiddenResultCount == 0
  and .canonicalRealModelBaseline.visualRecallAt10 >= 0.80
' "$repo_root/Results/LM-053/retrieval.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null

run_encoder_monitored "$result_root/retrieval-tests.txt" \
  env LM055_RETRIEVAL_PATH="$result_root/retrieval.json" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/HybridRetrievalBenchmarkTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/retrieval-tests.txt"
rg -q 'LM055_RETRIEVAL visual_recall_at_10=1.000000' "$result_root/retrieval-tests.txt"

run_encoder_monitored "$result_root/focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/HybridSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/VisualSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/ExactVisualVectorSearchTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"
rg -q 'LM053_VISUAL_RECALL_AT_10 1.0' "$result_root/focused-tests.txt"

run_encoder_monitored "$result_root/recovery-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$derived_data" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/ArchiveVectorStoreTests/testTruncationAndChecksumCorruptionNeverReturnResultsAndRebuild \
    -only-testing:LocalMemoryUnitTests/ArchiveVectorStoreTests/testCompactionDropsStaleVectorsAndRecoversBothCrashBoundaries \
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests/testRebuildRepairsMissingAndStaleRowsToExactReadyFrameParity \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/recovery-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/recovery-tests.txt") -eq 3 ]]

run_encoder_monitored "$result_root/scale-tests.txt" \
  env LM055_SCALE_TESTS=1 xcrun xctest \
    -XCTest ExactVisualVectorSearchTests/testLM055MillionFrameHybridLatencyAndMemory \
    "$derived_data/Build/Products/Release/LocalMemoryUnitTests.xctest"
rg -q 'Test Case .*testLM055MillionFrameHybridLatencyAndMemory.* passed' \
  "$result_root/scale-tests.txt"
rg -o 'LM055_SCALE_METRICS \{.*\}' "$result_root/scale-tests.txt" \
  | sed 's/^LM055_SCALE_METRICS //' >"$result_root/scale-metrics.json"
jq -e '
  .vectorCount == 1000000
  and .sampleCount == 20
  and .resultCount == 100
  and .p95Milliseconds < 750
  and .p99Milliseconds < 1000
  and .incrementalResidentMegabytes < 500
' "$result_root/scale-metrics.json" >/dev/null

retrieval_tmp="$result_root/retrieval.json.tmp"
jq \
  --slurpfile scale "$result_root/scale-metrics.json" \
  --slurpfile canonical "$repo_root/Results/LM-007/report.json" \
  --arg recoveryEvidence "Results/LM-055/recovery-tests.txt" \
  '. + {
    status: "passed",
    canonicalRealModel: {
      evidence: "Results/LM-007/report.json",
      visualRecallAt10: $canonical[0].results.visualRecallAt10,
      exactMillionVectorP95Milliseconds: $canonical[0].results.unfilteredP95Milliseconds,
      exactMillionVectorP99Milliseconds: $canonical[0].results.unfilteredP99Milliseconds
    },
    millionFrameHybrid: ($scale[0] + {evidence: "Results/LM-055/scale-tests.txt"}),
    reindexRecovery: {
      evidence: $recoveryEvidence,
      truncationAndChecksumFailClosed: true,
      vectorCompactionCrashRecovery: true,
      searchIndexParityRebuild: true
    },
    approximateIndexDecision: "not_required_exact_scan_passed_fixed_thresholds"
  }' "$result_root/retrieval.json" >"$retrieval_tmp"
mv "$retrieval_tmp" "$result_root/retrieval.json"
jq -e '
  .labelsEditedAfterFreeze == false
  and .visualHybridRecallAt10 >= 0.80
  and .hybrid.recallAt10 >= .lexicalOnly.recallAt10
  and .hybrid.recallAt10 >= .visualOnly.recallAt10
  and .hybrid.ndcgAt10 > .lexicalOnly.ndcgAt10
  and .hybrid.ndcgAt10 > .visualOnly.ndcgAt10
  and .duplicateResultRate < 0.15
  and .forbiddenResultCount == 0
  and .millionFrameHybrid.p95Milliseconds < 750
  and .reindexRecovery.searchIndexParityRebuild == true
' "$result_root/retrieval.json" >/dev/null

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-055 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

focused_test_count=$(rg -c 'Test Case .* passed' "$result_root/focused-tests.txt")
retrieval_test_count=$(rg -c 'Test Case .* passed' "$result_root/retrieval-tests.txt")
jq -n \
  --slurpfile retrieval "$result_root/retrieval.json" \
  --argjson focusedTests "$focused_test_count" \
  --argjson retrievalTests "$retrieval_test_count" \
  '{
    schemaVersion: 1,
    story: "LM-055",
    status: "passed",
    retrieval: $retrieval[0],
    verification: {
      frozenRetrievalTests: $retrievalTests,
      focusedSafeTests: $focusedTests,
      recoveryTests: 3,
      millionFrameSamples: 20,
      contracts: "passed",
      privacySmoke: "passed",
      releaseCompileOnly: "passed",
      dependencyAudit: "passed",
      strictFormatting: "passed"
    },
    safety: {
      applicationLaunchesExecuted: 0,
      appleImageIORuntimeExecuted: false,
      hardwareEncoderTestsExecuted: 0,
      videoToolboxInvocations: 0,
      encoderTripwire: "passed"
    }
  }' >"$result_root/report.json"

{
  echo "frozen_fixture_sha256=$fixture_hash"
  echo "hybrid_ranker=production_RRF_k60"
  echo "visual_fixture_candidates=LM053_full_engine_proof_plus_frozen_consensus_order"
  echo "million_frame_scanner=production_exact_accelerate"
  echo "million_frame_hybrid=production_concurrent_fusion_with_conservative_embedding_allowance"
  echo "approximate_index_required=false"
  echo "application_launches_executed=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/retrieval-tests.txt" "$result_root/focused-tests.txt" \
  "$result_root/recovery-tests.txt" "$result_root/scale-tests.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/retrieval-tests.txt" "$result_root/focused-tests.txt" \
  "$result_root/recovery-tests.txt" "$result_root/scale-tests.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "frozen_labels_unchanged=passed"
  echo "visual_recall_at_10=passed"
  echo "hybrid_ndcg_and_recall_non_regression=passed"
  echo "million_frame_hybrid_p95=passed"
  echo "reindex_and_recovery=passed"
  echo "exact_index_scale_decision=passed_no_adr"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-055 retrieval gate passed without app, ImageIO, or video runtime"
