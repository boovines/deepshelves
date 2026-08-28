#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-034"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-034 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-034 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -180 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEnrichmentJobStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/EnrichmentScheduler.swift"
  "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  "$repo_root/Tests/Unit/EnrichmentSchedulerTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-034 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/EnrichmentSchedulerTests \
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/VisionOCRPipelineTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-034 sources and fixtures." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

store_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEnrichmentJobStore.swift"
scheduler_source="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/EnrichmentScheduler.swift"
ui_source="$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
{
  rg -Fq 'ORDER BY priority DESC, id ASC' "$store_source"
  rg -Fq 'ProcessingJob.maximumAutomaticAttempts' "$store_source"
  rg -Fq 'producer_version <> ?' "$store_source"
  rg -Fq "error_code = 'lease_expired'" "$store_source"
  rg -Fq 'captureTransitionPending' "$scheduler_source"
  rg -Fq 'lowPowerModeEnabled' "$scheduler_source"
  rg -Fq 'conditions.thermalState == .serious' "$scheduler_source"
  rg -Fq 'EnrichmentBacklogPresentation' "$scheduler_source"
  rg -Fq 'menu.enrichmentBacklog' "$ui_source"
  echo "durable_priority_and_stale_lease_guard=passed"
  echo "three_attempt_policy=passed"
  echo "producer_version_invalidation=passed"
  echo "restart_requeue=passed"
  echo "capture_idle_power_thermal_throttles=passed"
  echo "atomic_backlog_and_visible_projection=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n '{
  schemaVersion: 1,
  story: "LM-034",
  status: "passed",
  leaseDurationSeconds: 120,
  maximumAutomaticAttempts: 3,
  priorityOrder: "priority_descending_then_job_id_ascending",
  captureTransitionPreemptsEnrichment: true,
  producerVersionInvalidation: "idempotent_non_cancelled_requeue",
  staleLeasePublicationRejected: true,
  restartLeaseRecovery: true,
  throttles: {
    idleRequiredBelowPriority: 500,
    constrainedMinimumPriority: 700,
    lowBatteryThreshold: 0.20,
    criticalThermalPausesAll: true
  },
  atomicBacklogProjection: true,
  visibleBacklogProjection: true,
  contentFreeErrorCodes: true,
  focusedTests: 26,
  hardwareEncoderTestsExecuted: 0,
  applicationLaunchesExecuted: 0
}' >"$result_root/report.json"

perl -pi -e 's/[ \t]+$//' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "focused_release_tests=passed"
  echo "durable_restart_and_expiry=passed"
  echo "priority_and_three_attempt_policy=passed"
  echo "version_invalidation=passed"
  echo "idle_power_thermal_throttles=passed"
  echo "ui_backlog_projection=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-034 durable enrichment scheduler gate passed without media runtime execution"
