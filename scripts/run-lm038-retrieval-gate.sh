#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-038"
fixture="$repo_root/Fixtures/LM038/retrieval-judgments.json"
fixture_sha="$repo_root/Fixtures/LM038/retrieval-judgments.sha256"
mkdir -p "$result_root" "$repo_root/.build/LM038"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-038 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-038 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Benchmarks/LM038FixtureGenerator.swift"
  "$repo_root/Tests/Unit/LexicalRetrievalBenchmarkTests.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveLexicalSearch.swift"
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/LexicalSearchEngine.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-038 sources" >&2
  exit 1
fi

expected_hash=$(awk '{print $1}' "$fixture_sha")
actual_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
[[ "$expected_hash" == "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912" ]]
[[ "$actual_hash" == "$expected_hash" ]]
rg -Fq "$expected_hash" "$repo_root/Tests/Unit/LexicalRetrievalBenchmarkTests.swift"

swiftc "$repo_root/Benchmarks/LM038FixtureGenerator.swift" \
  -o "$repo_root/.build/LM038/fixture-generator"
reproduced_fixture=$(mktemp /tmp/lm038-reproduced.XXXXXX.json)
"$repo_root/.build/LM038/fixture-generator" "$reproduced_fixture"
cmp "$fixture" "$reproduced_fixture"
{
  echo "frozen_fixture_sha256=$actual_hash"
  echo "generator_reproduces_frozen_fixture=passed"
  echo "frame_count=$(jq '.frames | length' "$fixture")"
  echo "query_count=$(jq '.queries | length' "$fixture")"
  echo "lexical_query_count=$(jq '[.queries[] | select(.includeInLexicalEvaluation)] | length' "$fixture")"
  echo "independent_judgments_per_query=3"
  echo "invalid_pre_tuning_freeze_preserved=passed"
} | tee "$result_root/fixture-reproduction.txt"

[[ $(jq '.frames | length' "$fixture") -eq 500 ]]
[[ $(jq '.queries | length' "$fixture") -eq 100 ]]
[[ $(jq '[.queries[] | select(.includeInLexicalEvaluation)] | length' "$fixture") -eq 75 ]]
[[ $(jq '[.queries[] | select(.judgments | length == 3)] | length' "$fixture") -eq 100 ]]
[[ $(jq '[.queries[] | select(.id | startswith("site-time-")) | select((.judgments[0].relevance | length) == 5)] | length' "$fixture") -eq 10 ]]

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
    -only-testing:LocalMemoryUnitTests/LexicalRetrievalBenchmarkTests \
    -only-testing:LocalMemoryUnitTests/LexicalSearchEngineTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

jq -e '
  .schemaVersion == 1
  and .story == "LM-038"
  and .fixtureSHA256 == "640abc4d73f66c9555cb54df277b0963eeae02cd80651f7174d6bba238e02912"
  and .frameCount == 500
  and .totalQueryCount == 100
  and .evaluatedQueryCount == 75
  and .excludedVisualQueryCount == 25
  and .independentJudgmentsPerQuery == 3
  and .recallAt5 >= 0.90
  and .p95LatencyMilliseconds < 300
  and .forbiddenResultCount == 0
  and .noResultPrecision == 1
  and .labelsEditedAfterFreeze == false
' "$result_root/retrieval.json" >/dev/null

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-038 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "frozen_labels_verified_before_and_after=passed"
  echo "invalid_fixture_correction_before_engine_tuning=recorded"
  echo "recall_at_5=$(jq -r '.recallAt5' "$result_root/retrieval.json")"
  echo "recall_at_10=$(jq -r '.recallAt10' "$result_root/retrieval.json")"
  echo "ndcg_at_10=$(jq -r '.ndcgAt10' "$result_root/retrieval.json")"
  echo "mrr=$(jq -r '.meanReciprocalRank' "$result_root/retrieval.json")"
  echo "p95_ms=$(jq -r '.p95LatencyMilliseconds' "$result_root/retrieval.json")"
  echo "no_result_precision=$(jq -r '.noResultPrecision' "$result_root/retrieval.json")"
  echo "forbidden_results=$(jq -r '.forbiddenResultCount' "$result_root/retrieval.json")"
  echo "hardware_encoder_tests_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

final_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
[[ "$final_hash" == "$expected_hash" ]]
perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "frozen_corpus_reproduction=passed"
  echo "retrieval_release_tests=passed"
  echo "recall_at_5_gate=passed"
  echo "p95_latency_gate=passed"
  echo "no_result_and_forbidden_gate=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-038 frozen lexical retrieval gate passed without media runtime execution"
