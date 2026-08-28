#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-049"
resource_root="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/Resources/MobileCLIP-S0"
manifest="$resource_root/model-manifest.json"
expected_manifest_hash="758468b14a34070a0f6295fe8b6fd4d1b8cf536083cbb10c847fd5dae3cc762b"
expected_image_parity_hash="a3a3afd8b84c89adaef28aa446b89e06c18bba2f4971352ef6761952f2a2a6e4"
expected_text_parity_hash="cf50c94daf5e3dc186fa6ff018181639b4516b74495089478ef40d1f60010008"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-049 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-049 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ModelResourceIntegrity.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/MobileCLIPModelService.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/MobileCLIPPreprocessing.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/MobileCLIPRuntime.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/MobileCLIPTokenizer.swift"
  "$repo_root/Tests/Unit/MobileCLIPModelTests.swift"
  "$repo_root/Tests/Integration/MobileCLIPIntegrationTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-049 sources" >&2
  exit 1
fi

actual_manifest_hash=$(shasum -a 256 "$manifest" | awk '{print $1}')
[[ "$actual_manifest_hash" == "$expected_manifest_hash" ]]
[[ $(jq '.artifacts | length' "$manifest") -eq 12 ]]
[[ $(find "$resource_root" -type l -print | wc -l | tr -d ' ') -eq 0 ]]
actual_resource_bytes=$(find "$resource_root" -type f -exec stat -f '%z' {} + \
  | awk '{sum += $1} END {print sum}')
[[ "$actual_resource_bytes" -eq 112239644 ]]

parity_root="$repo_root/Benchmarks/Results/S3S4/20260827T193136Z/raw"
[[ $(shasum -a 256 "$parity_root/packaged-parity-image.f32" | awk '{print $1}') \
  == "$expected_image_parity_hash" ]]
[[ $(shasum -a 256 "$parity_root/source-parity-image.f32" | awk '{print $1}') \
  == "$expected_image_parity_hash" ]]
[[ $(shasum -a 256 "$parity_root/packaged-parity-text.f32" | awk '{print $1}') \
  == "$expected_text_parity_hash" ]]
[[ $(shasum -a 256 "$parity_root/source-parity-text.f32" | awk '{print $1}') \
  == "$expected_text_parity_hash" ]]
jq -e '
  .model.version == "mobileclip-s0-coreml-3e0a7bf"
  and .model.embeddingDimension == 512
  and .model.artifactCount == 12
  and .model.verifiedArtifactCount == 12
  and .model.bundledFootprintBytes == 112239644
  and .results.imageCosineSimilarity >= 0.999999
  and .results.textCosineSimilarity >= 0.999999
  and .results.visualRecallAt10 >= 0.80
' "$repo_root/Results/LM-007/report.json" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/unit-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM049" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/MobileCLIPModelTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/unit-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/unit-tests.txt") -eq 8 ]]

run_encoder_monitored "$result_root/inference-parity.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM049" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryIntegrationTests/MobileCLIPIntegrationTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/inference-parity.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/inference-parity.txt") -eq 2 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-049 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
run_encoder_monitored "$result_root/privacy.txt" "$repo_root/scripts/privacy-smoke.sh"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

{
  echo "model_version=mobileclip-s0-coreml-3e0a7bf"
  echo "manifest_sha256=$actual_manifest_hash"
  echo "artifact_count=12"
  echo "bundled_footprint_bytes=$actual_resource_bytes"
  echo "embedding_dimension=512"
  echo "token_context_length=77"
  echo "image_preprocessing=aspect-fill-center-crop-bilinear-srgb-bgra256"
  echo "canonical_s3_image_vector_sha256=$expected_image_parity_hash"
  echo "canonical_s3_text_vector_sha256=$expected_text_parity_hash"
  echo "typed_fail_closed_startup=passed"
  echo "corrupted_model_results=0"
  echo "runtime_downloads=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/unit-tests.txt" "$result_root/inference-parity.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/unit-tests.txt" "$result_root/inference-parity.txt" \
  "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "pinned_manifest_and_exact_inventory=passed"
  echo "corruption_rewrite_symlink_extra_duplicate_rejection=passed"
  echo "frozen_tokenizer_preprocessing=passed"
  echo "deterministic_image_preprocessing=passed"
  echo "typed_startup_unavailable_state=passed"
  echo "canonical_s3_parity_vectors=passed"
  echo "bundled_image_text_inference=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-049 bundled MobileCLIP gate passed without app, ImageIO, or video runtime"
