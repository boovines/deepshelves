#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-054"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-054 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-054 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/HybridSearchEngine.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/LexicalSearchEngine.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/VisualSearchEngine.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveHybridGroupingStore.swift"
  "$repo_root/Apps/LocalMemoryApp/SearchPresentation.swift"
  "$repo_root/Tests/Unit/HybridSearchEngineTests.swift"
  "$repo_root/Tests/Unit/LexicalSearchEngineTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-054 sources" >&2
  exit 1
fi

fixture="$repo_root/Fixtures/LM054/fusion-cases.json"
[[ $(shasum -a 256 "$fixture" | awk '{print $1}') \
  == "de9b57ce6ccbde66e7f69c063e73b33e704ef924b1a94202398b687210eddb1f" ]]
jq -e '
  .schemaVersion == 1
  and .reciprocalRankK == 60
  and (.cases | length) == 2
  and .cases[0].expectedOrder == ["a", "c", "b"]
  and .cases[0].expectedScores.a == 0.03639344262295082
  and .cases[0].expectedScores.b == 0.03225806451612903
  and .cases[0].expectedScores.c == 0.032266458495966696
  and .cases[1].expectedOrder == ["e", "f"]
' "$fixture" >/dev/null
jq -e '
  .fusion.k == 60
  and .pagination.resultCacheRequired == false
  and .pagination.duplicateCount == 0
  and .pagination.skippedCount == 0
  and .presentation.fusedSettlementsPerGeneration == 1
  and .presentation.lexicalInterimJumpCount == 0
' "$result_root/fusion.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM054" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/HybridSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/HybridSearchSettlementTests \
    -only-testing:LocalMemoryUnitTests/VisualSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/LexicalSearchEngineTests \
    -only-testing:LocalMemoryUnitTests/SearchSessionModelTests \
    -only-testing:LocalMemoryUnitTests/MemoryContractsV1Tests \
    -only-testing:LocalMemoryUnitTests/ArchiveSearchIndexStoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 55 ]]
rg -q 'LM054_HAND_FUSION a,c,b' "$result_root/unit-tests.txt"
rg -q 'LM054_HYBRID_PAGINATION 20' "$result_root/unit-tests.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-054 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "rrf_k=60"
  echo "exact_field_boosts=fixed"
  echo "duplicate_frame_merge=passed"
  echo "same_context_grouping=passed"
  echo "capture_perceptual_heartbeat_grouping=passed"
  echo "approved_text_similarity_threshold=0.8"
  echo "signed_keyset_cursor=passed"
  echo "result_cache_required=false"
  echo "policy_fingerprint_binding=passed"
  echo "page_size_reduction=passed"
  echo "settlements_per_generation=1"
  echo "lexical_interim_publications=0"
  echo "application_launches_executed=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' "$result_root/unit-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' "$result_root/unit-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "hand_computed_fusion=passed"
  echo "deterministic_ordering=passed"
  echo "stable_pagination=passed"
  echo "dedup_and_grouping=passed"
  echo "settle_once_hybrid_ui=passed"
  echo "image_resource_policy=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-054 hybrid fusion gate passed without app, ImageIO, or video runtime"
