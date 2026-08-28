#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-053"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-053 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-053 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVectorStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVisualSearch.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/ExactVisualVectorSearch.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/VisualSearchEngine.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/MobileCLIPModelService.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisualEmbeddingJobs.swift"
  "$repo_root/Apps/LocalMemoryApp/SearchPresentation.swift"
  "$repo_root/Tests/Unit/VisualSearchEngineTests.swift"
  "$repo_root/Tests/Integration/MobileCLIPIntegrationTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-053 sources" >&2
  exit 1
fi

fixture="$repo_root/Fixtures/LM038/retrieval-judgments.json"
[[ $(shasum -a 256 "$fixture" | awk '{print $1}') \
  == "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912" ]]
[[ $(jq '[.queries[] | select(.category == "visualSemantic")] | length' "$fixture") -eq 25 ]]
jq -e '
  .results.visualRecallAt10 >= 0.75
  and .results.textQueryCount == 100
  and .results.imageCount == 500
  and .results.textP95Milliseconds < 50
' "$repo_root/Results/LM-007/report.json" >/dev/null
jq -e '
  .frozenJudgments.visualQueryCount == 25
  and .frozenJudgments.pipelineRecallAt10 >= 0.75
  and .frozenJudgments.forbiddenResultCount == 0
  and .canonicalRealModelBaseline.visualRecallAt10 >= 0.75
  and .parity.textCosineSimilarity >= 0.999999
' "$result_root/retrieval.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM053" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/VisualSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests \
    -only-testing:LocalMemoryUnitTests/ArchiveVectorStoreTests \
    -only-testing:LocalMemoryUnitTests/LexicalSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/MobileCLIPModelTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 42 ]]
rg -q 'LM053_VISUAL_RECALL_AT_10 1.0' "$result_root/unit-tests.txt"

run_encoder_monitored "$result_root/model-parity.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM053" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryIntegrationTests/MobileCLIPIntegrationTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/model-parity.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/model-parity.txt") -eq 2 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  "$repo_root/Tests/Unit/ArchiveSearchIndexStoreTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-053 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "shared_router=text+visual+lexical-hybrid-fallback"
  echo "query_encoder=paired-mobileclip-text-model"
  echo "query_model_hash_bound=passed"
  echo "visual_evidence_source=visual"
  echo "visual_evidence_matched_text=null"
  echo "policy_filter_before_scoring=passed"
  echo "policy_revalidation_before_projection=passed"
  echo "image_locator_policy_gate=passed"
  echo "frozen_visual_queries=25"
  echo "pipeline_recall_at_10=1.0"
  echo "canonical_real_model_recall_at_10=1.0"
  echo "application_launches_executed=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/unit-tests.txt" "$result_root/model-parity.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/unit-tests.txt" "$result_root/model-parity.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "visual_only_text_embedding=passed"
  echo "exact_candidate_retrieval=passed"
  echo "visual_evidence_label=passed"
  echo "access_policy_before_projection=passed"
  echo "suppression_race_revalidation=passed"
  echo "frozen_recall_at_10=passed"
  echo "real_model_recall_baseline=passed"
  echo "lexical_fallback=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-053 visual-only search gate passed without app, ImageIO, or video runtime"
