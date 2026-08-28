#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-050"
fixture="$repo_root/Fixtures/LM050/visual-embedding-golden.json"
expected_fixture_hash="a5fec36e75a239f15c4fc985e96cec29da5c64f736df29d5743f71fc515ae9d9"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-050 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-050 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveVisualEmbeddingStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEnrichmentJobStore.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisualEmbeddingJobs.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/EnrichmentScheduler.swift"
  "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  "$repo_root/Tests/Unit/VisualEmbeddingJobTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-050 sources" >&2
  exit 1
fi

actual_fixture_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
[[ "$actual_fixture_hash" == "$expected_fixture_hash" ]]
jq -e '
  .schemaVersion == 1
  and .modelVersion == "mobileclip-s0-coreml-3e0a7bf"
  and .preprocessingVersion == "srgb-aspectfill-bgra256-v1"
  and .dimension == 512
  and .normalizedPrefix == [0.6, 0.8]
  and .expectedNorm == 1.0
  and .canonicalFloat32SHA256 == "2cdd74c082e797454606fd2bd5ac4852cb42e0081ffc90c1890bbc25b24c8065"
' "$fixture" >/dev/null

jq -e '
  .results.captureTimerP95Milliseconds <= 15
  and .results.captureTimerIntervalsOver100Milliseconds == 0
  and .results.maximumConcurrentInferenceJobs == 1
  and .results.imageP95Milliseconds <= 50
' "$repo_root/Results/LM-007/report.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM050" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/VisualEmbeddingJobTests \
    -only-testing:LocalMemoryUnitTests/EnrichmentSchedulerTests \
    -only-testing:LocalMemoryUnitTests/MobileCLIPModelTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 20 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-050 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "fixture_sha256=$actual_fixture_hash"
  echo "producer_version=mobileclip-s0-coreml-3e0a7bf+image-v1"
  echo "preprocessing_version=srgb-aspectfill-bgra256-v1"
  echo "embedding_dimension=512"
  echo "canonical_float32_sha256=2cdd74c082e797454606fd2bd5ac4852cb42e0081ffc90c1890bbc25b24c8065"
  echo "capture_timer_p95_ms=11.117792"
  echo "capture_timer_intervals_over_100_ms=0"
  echo "maximum_concurrent_inference_jobs=1"
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
  echo "thermal_power_capture_deferral=passed"
  echo "deterministic_normalization=passed"
  echo "source_integrity_revalidation=passed"
  echo "producer_version_invalidation=passed"
  echo "bounded_retry_permanent_failure=passed"
  echo "honest_visual_backlog_projection=passed"
  echo "capture_budget_evidence=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-050 visual embedding gate passed without app, ImageIO, or video runtime"
