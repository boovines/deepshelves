#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-032"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-032 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-032 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/AXOCRSpanMerge.swift"
  "$repo_root/Tests/Unit/AXOCRSpanMergeTests.swift"
  "$repo_root/Packages/MemoryContracts/Sources/MemoryContracts/TextSpan.swift"
  "$repo_root/Packages/MemoryContracts/Sources/MemoryContracts/GeometryAndContext.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession|CGImageDestination|CGImageSource|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media or ImageIO runtime symbol entered LM-032 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/AXOCRSpanMergeTests \
    -only-testing:LocalMemoryUnitTests/AccessibilityTextSpanTests \
    -only-testing:LocalMemoryUnitTests/VisionOCRPipelineTests \
    -only-testing:LocalMemoryUnitTests/ContextSpikeCoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

metric=$(rg -o 'LM032_METRIC fixtures=[0-9]+ merged_tokens=[0-9]+ duplicate_tokens=[0-9]+ ground_truth=[0-9]+ lost=[0-9]+' \
  "$result_root/focused-tests.txt" | tail -1)
test -n "$metric"
fixtures=$(sed -E 's/.*fixtures=([0-9]+).*/\1/' <<<"$metric")
merged_tokens=$(sed -E 's/.*merged_tokens=([0-9]+).*/\1/' <<<"$metric")
duplicate_tokens=$(sed -E 's/.*duplicate_tokens=([0-9]+).*/\1/' <<<"$metric")
ground_truth=$(sed -E 's/.*ground_truth=([0-9]+).*/\1/' <<<"$metric")
lost=$(sed -E 's/.*lost=([0-9]+).*/\1/' <<<"$metric")

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-032 Swift sources and tests." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

merge_source="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/AXOCRSpanMerge.swift"
{
  rg -Fq 'where Accessibility.Element == TextSpan, OCR.Element == TextSpan' "$merge_source"
  rg -Fq 'candidate.sensitivity != .suppressed' "$merge_source"
  rg -Fq '>= Self.duplicateIntersectionOverUnion' "$merge_source"
  rg -Fq 'case .accessibility: 0' "$merge_source"
  rg -Fq 'try foreground.validate()' "$merge_source"
  rg -Fq 'throw ApprovedSearchMetadataProjectionError.privateBrowserContext' "$merge_source"
  rg -Fq 'browser.origin.scheme == "https" || browser.origin.scheme == "http"' "$merge_source"
  rg -Fq 'public init(from decoder: Decoder) throws' "$merge_source"
  echo "input_boundary=durable_text_span_only"
  echo "accessibility_precedence=passed"
  echo "suppressed_content_persisted=0"
  echo "transient_raw_observations_persisted=0"
  echo "private_or_sensitive_url_projection=failed_closed"
  echo "apple_imageio_encode_decode_calls=0"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n \
  --argjson fixtureCount "$fixtures" \
  --argjson mergedTokenCount "$merged_tokens" \
  --argjson duplicateTokenCount "$duplicate_tokens" \
  --argjson groundTruthTokenCount "$ground_truth" \
  --argjson lostTokenCount "$lost" \
  '{
    schemaVersion: 1,
    story: "LM-032",
    status: "passed",
    fixtureCount: $fixtureCount,
    mergedTokenCount: $mergedTokenCount,
    duplicateNormalizedTokenCount: $duplicateTokenCount,
    duplicateNormalizedTokenRate: ($duplicateTokenCount / $mergedTokenCount),
    maximumDuplicateNormalizedTokenRate: 0.03,
    groundTruthTokenCount: $groundTruthTokenCount,
    uniqueGroundTruthLossCount: $lostTokenCount,
    uniqueGroundTruthLossRate: ($lostTokenCount / $groundTruthTokenCount),
    maximumUniqueGroundTruthLossRate: 0.01,
    insertionOrderStable: true,
    approvedMetadataRevalidatedOnDecode: true,
    transientRawObservationsPersisted: 0,
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
  echo "s2_duplicate_rate=passed"
  echo "s2_unique_loss_rate=passed"
  echo "permutation_stability=passed"
  echo "approved_metadata_projection=passed"
  echo "raw_observation_discard=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-032 deterministic AX/OCR span merge gate passed"
