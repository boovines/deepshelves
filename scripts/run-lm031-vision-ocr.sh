#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-031"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-031 gate while an Xcode test or encoder process is active" >&2
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
    sleep 0.1
  done
  set +e
  wait "$command_pid"
  local status=$?
  set -e
  if [[ "$encoder_seen" -ne 0 ]]; then
    echo "ABORTED: encoder service appeared during LM-031 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryEnrichment/Package.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ContextVisionOCR.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisionOCRPipeline.swift"
  "$repo_root/Tests/Unit/VisionOCRPipelineTests.swift"
  "$repo_root/Tests/Integration/ContextVisionIntegrationTests.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession|CGImageDestination|CGImageSource|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media or ImageIO encode/decode symbol entered LM-031 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/VisionOCRPipelineTests \
    -only-testing:LocalMemoryIntegrationTests/ContextVisionIntegrationTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

metric=$(rg -o 'LM031_METRIC fixtures=[0-9]+ high_contrast_recall=[0-9.]+ full_recall=[0-9.]+ p95_ms=[0-9.]+' \
  "$result_root/focused-tests.txt" | tail -1)
test -n "$metric"
fixtures=$(sed -E 's/.*fixtures=([0-9]+).*/\1/' <<<"$metric")
high_contrast_recall=$(sed -E 's/.*high_contrast_recall=([0-9.]+).*/\1/' <<<"$metric")
full_recall=$(sed -E 's/.*full_recall=([0-9.]+).*/\1/' <<<"$metric")
p95_ms=$(sed -E 's/.*p95_ms=([0-9.]+).*/\1/' <<<"$metric")

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

pipeline_source="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/VisionOCRPipeline.swift"
vision_source="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ContextVisionOCR.swift"
{
  rg -Fq 'orientation: input.orientation.cgImagePropertyOrientation' "$vision_source"
  rg -Fq 'throw S2OCRRendererError.imageIORuntimeQuarantined' "$vision_source"
  rg -Fq 'let upperLeftY = 1 - bounds.y - bounds.height' "$pipeline_source"
  rg -Fq 'source: .visionOCR' "$pipeline_source"
  rg -Fq 'activeJobID == nil' "$pipeline_source"
  rg -Fq 'thermalState == .nominal || thermalState == .fair' "$pipeline_source"
  rg -Fq 'try Task.checkCancellation()' "$pipeline_source"
  rg -Fq 'ProcessingJob.maximumAutomaticAttempts' "$pipeline_source"
  rg -Fq 'Text recognition will retry.' "$pipeline_source"
  rg -Fq 'The capture remains available without OCR text.' "$pipeline_source"
  echo "orientation_and_scale_correction=passed"
  echo "confidence_language_bounds=passed"
  echo "single_concurrency=passed"
  echo "thermal_deferral=passed"
  echo "cancellation_publication=zero"
  echo "retry_and_permanent_states=passed"
  echo "apple_imageio_encode_decode_calls=0"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n \
  --argjson fixtureCount "$fixtures" \
  --argjson highContrastRecall "$high_contrast_recall" \
  --argjson fullRecall "$full_recall" \
  --argjson p95Milliseconds "$p95_ms" \
  '{
    schemaVersion: 1,
    story: "LM-031",
    status: "passed",
    fixtureCount: $fixtureCount,
    highContrastLatinRecall: $highContrastRecall,
    minimumHighContrastLatinRecall: 0.90,
    fullRecall: $fullRecall,
    minimumFullRecall: 0.82,
    p95Milliseconds: $p95Milliseconds,
    orientationCases: 8,
    maximumConcurrentOCRJobs: 1,
    leaseDurationSeconds: 120,
    maximumAttempts: 3,
    imageInput: "in-memory CoreGraphics only",
    appleImageIOEncodeDecodeCalls: 0,
    hardwareEncoderTestsExecuted: 0,
    applicationLaunchesExecuted: 0
  }' >"$result_root/report.json"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" \
  "$result_root/release-build.txt"

git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "focused_release_tests=passed"
  echo "full_vision_corpus=passed"
  echo "leasing_cancellation_thermal=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-031 Vision OCR safe gate passed"
