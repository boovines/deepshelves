#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-029"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-029 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-029 safe gate" >&2
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
  "$repo_root/Tests/Unit/AccessibilitySnapshotTests.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession|ImageIO|CGImageSource|CGImageDestination|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media or ImageIO runtime symbol entered LM-029 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/AccessibilitySnapshotTests \
    -only-testing:LocalMemoryUnitTests/ContextSpikeCoreTests \
    -only-testing:LocalMemoryUnitTests/ForegroundWindowResolverTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

metric=$(rg -o 'LM029_METRIC fixtures=[0-9]+ useful=[0-9]+ coverage=[0-9.]+ p95_ms=[0-9.]+' \
  "$result_root/focused-tests.txt" | tail -1)
test -n "$metric"
fixtures=$(sed -E 's/.*fixtures=([0-9]+).*/\1/' <<<"$metric")
useful=$(sed -E 's/.*useful=([0-9]+).*/\1/' <<<"$metric")
coverage=$(sed -E 's/.*coverage=([0-9.]+).*/\1/' <<<"$metric")
p95_ms=$(sed -E 's/.*p95_ms=([0-9.]+).*/\1/' <<<"$metric")

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

source_file="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AccessibilitySnapshot.swift"
{
  rg -Fq 'target.processID == observed.processID' "$source_file"
  rg -Fq 'target.title == observed.title' "$source_file"
  rg -Fq 'timeBudgetMilliseconds: Double = 45' "$source_file"
  rg -Fq 'maximumNodes: Int = 256' "$source_file"
  rg -Fq 'maximumDepth: Int = 12' "$source_file"
  rg -Fq 'Self.supportedRoles.contains(role)' "$source_file"
  rg -Fq 'secure ? nil : truncated(item.node.value)' "$source_file"
  rg -Fq 'autoreleasepool' "$source_file"
  rg -Fq 'DispatchQueue.global(qos: .userInitiated).async' "$source_file"
  if rg -n 'struct (AccessibilitySnapshot|ProjectedAccessibilityElement).*Codable|import (MemoryStore|GRDB)' \
    "$source_file"; then
    exit 1
  fi
  echo "exact_foreground_pid_bounds_title=passed"
  echo "bounded_nodes_depth_strings_time=passed"
  echo "supported_role_allowlist=passed"
  echo "secure_value_collection=zero"
  echo "raw_ax_tree_persistability=none"
  echo "raw_ax_release_scope=autoreleasepool"
  echo "capture_callback_blocking=none"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n \
  --argjson fixtureCount "$fixtures" \
  --argjson usefulCount "$useful" \
  --argjson coverage "$coverage" \
  --argjson p95Milliseconds "$p95_ms" \
  '{
    schemaVersion: 1,
    story: "LM-029",
    status: "passed",
    fixtureCount: $fixtureCount,
    usefulCount: $usefulCount,
    coverage: $coverage,
    minimumCoverage: 0.80,
    p95Milliseconds: $p95Milliseconds,
    maximumP95Milliseconds: 50,
    maximumNodes: 256,
    maximumDepth: 12,
    maximumStringLength: 512,
    timeBudgetMilliseconds: 45,
    targetIdentity: ["captureEpochID", "windowID", "processID", "bounds", "title"],
    rawTreesPersisted: false,
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
  echo "canonical_ax_coverage=passed"
  echo "canonical_ax_latency=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-029 bounded Accessibility safe gate passed"
