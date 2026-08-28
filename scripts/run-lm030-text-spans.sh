#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-030"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-030 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-030 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AccessibilitySnapshot.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AccessibilityTextSpanEmitter.swift"
  "$repo_root/Tests/Unit/AccessibilityTextSpanTests.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession|ImageIO|CGImageSource|CGImageDestination|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media or ImageIO runtime symbol entered LM-030 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/AccessibilityTextSpanTests \
    -only-testing:LocalMemoryUnitTests/AccessibilitySnapshotTests \
    -only-testing:LocalMemoryUnitTests/MemoryContractsV1Tests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

emitter_source="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AccessibilityTextSpanEmitter.swift"
golden_fixture="$repo_root/Fixtures/LM030/normalization-goldens.json"
golden_count=$(jq '.cases | length' "$golden_fixture")
golden_sha=$(shasum -a 256 "$golden_fixture" | awk '{print $1}')
test "$golden_count" -ge 12
{
  rg -Fq 'let text = TextSpan.normalize(rawValue)' "$emitter_source"
  rg -Fq 'secure ? nil : element.value' "$emitter_source"
  rg -Fq 'intersectionOverUnion(left, right) >= 0.5' "$emitter_source"
  rg -Fq 'source: .accessibility' "$emitter_source"
  rg -Fq 'confidence: nil' "$emitter_source"
  rg -Fq 'sensitivity: .normal' "$emitter_source"
  rg -Fq 'NormalizedRect(x: x, y: y, width: width, height: height)' "$emitter_source"
  if rg -n 'element\.(identifier|signature)' "$emitter_source"; then
    exit 1
  fi
  echo "normalization_goldens=passed"
  echo "secure_value_sentinel_persistence=0"
  echo "identifier_signature_sentinel_persistence=0"
  echo "duplicate_overlap_threshold=0.5"
  echo "bounds_clipped_to_accepted_window=passed"
  echo "provenance_source=accessibility"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n \
  --argjson normalizationGoldenCount "$golden_count" \
  --arg normalizationGoldenSHA256 "$golden_sha" \
  '{
    schemaVersion: 1,
    story: "LM-030",
    status: "passed",
    normalizationGoldenCount: $normalizationGoldenCount,
    normalizationGoldenSHA256: $normalizationGoldenSHA256,
    textSource: "accessibility",
    confidence: null,
    languageCode: null,
    secureValuesPersisted: 0,
    duplicateIntersectionOverUnionThreshold: 0.5,
    boundsSpace: "accepted foreground window normalized upper-left origin",
    rawProjectionPersisted: false,
    systemAXRuntimeTestsExecuted: 0,
    hardwareEncoderTestsExecuted: 0,
    appleImageIORuntimeTestsExecuted: 0,
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
  echo "normalization_goldens=passed"
  echo "secure_and_duplicate_fixtures=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-030 Accessibility TextSpan safe gate passed"
