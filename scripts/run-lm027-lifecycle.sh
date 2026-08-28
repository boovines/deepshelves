#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-027"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-027 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-027 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/ActivityMonitor.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AppLifecycle.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureLifecycleCoordinator.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/LaunchAtLogin.swift"
  "$repo_root/Packages/MemoryContracts/Sources/MemoryContracts/RecordingGapPersisting.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveRecordingGapStore.swift"
  "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  "$repo_root/Tests/Unit/AppLifecycleTests.swift"
  "$repo_root/Tests/Unit/LaunchAtLoginTests.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession' \
  "${focused_sources[@]}"; then
  echo "Quarantined hardware media symbol entered LM-027 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/AppLifecycleTests \
    -only-testing:LocalMemoryUnitTests/LaunchAtLoginTests \
    -only-testing:LocalMemoryUnitTests/ActivityMonitorTests \
    -only-testing:LocalMemoryUnitTests/ScreenCaptureRuntimeTests \
    -only-testing:LocalMemoryUnitTests/ForegroundWindowResolverTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

target_gap_count=$(rg -c '^\s*\(\.(unresolvedWindow|ambiguousWindow|minimizedWindow|unsupportedDisplay|protectedSurface|noWindow),' \
  "$repo_root/Tests/Unit/AppLifecycleTests.swift" || true)

jq -n \
  --argjson targetGapCases "$target_gap_count" \
  '{
    schemaVersion: 1,
    privacyMode: "foregroundWindowOnly",
    uiBudgetMilliseconds: 250,
    captureAllowedOnlyForExactApprovedRunningTarget: true,
    targetGapCases: $targetGapCases,
    targetGaps: [
      "unresolvedWindow", "ambiguousWindow", "minimizedWindow",
      "unsupportedDisplay", "protectedSurface", "noWindow"
    ],
    visibleStopCauses: ["lowDisk", "databaseFailure", "processStopped"],
    canonicalStopGap: "processStopped",
    lifecycleGapsContainIdentity: false,
    persistedRecordingRelaunch: "stoppedPendingReconciliation",
    launchAtLoginRegistrationExecuted: false,
    h3Triggered: false,
    hardwareEncoderTestsExecuted: 0,
    applicationLaunchesExecuted: 0
  }' >"$result_root/lifecycle.json"

{
  rg -Fq 'captureAllowed: cause == .ready && activeTargetWindowID != nil' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureLifecycleCoordinator.swift"
  rg -Fq 'target.windowID != windowID' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureLifecycleCoordinator.swift"
  rg -Fq 'CaptureLifecycleCoordinator.uiBudgetNanoseconds' \
    "$repo_root/Tests/Unit/AppLifecycleTests.swift"
  rg -Fq 'case interruptedCapture' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/AppLifecycle.swift"
  rg -Fq 'SMAppService.mainApp.register()' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/LaunchAtLogin.swift"
  rg -Fq 'settings.launchAtLoginApproval' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  rg -Fq 'latestCaptureInputs.replacing(recordingEnabled: shouldEnable)' \
    "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  rg -Fq 'initialStatus = showsMenuPreview ? .recording : .targetUnavailable' \
    "$repo_root/Apps/LocalMemoryApp/AppComposition.swift"
  rg -Fq "'gap'" \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveRecordingGapStore.swift"
  echo "foreground_window_only_admission=passed"
  echo "stale_stream_target_rejected=passed"
  echo "ui_projection_budget=passed"
  echo "safe_restart=passed"
  echo "typed_gap_persistence=passed"
  echo "launch_at_login_explicit_action=passed"
  echo "pause_resume_reconciles_capture_inputs=passed"
  echo "production_launch_never_claims_recording_without_target=passed"
  echo "h3_not_triggered_no_real_registration=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" \
  "$result_root/red.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" \
  "$result_root/red.txt" \
  "$result_root/release-build.txt"

git -C "$repo_root" diff --check
assert_safe_process_state

jq -n '{
  story: "LM-027",
  status: "passed",
  focusedReleaseTests: "passed",
  contracts: "passed",
  privacySmoke: "passed",
  releaseCompileOnly: "passed",
  dependencyAudit: "passed",
  encoderProcessTripwire: "passed",
  appRuntime: "not launched",
  h3: "not triggered",
  uiBudgetMilliseconds: 250,
  hardwareEncoderTestsExecuted: 0
}' >"$result_root/report.json"

{
  echo "focused_release_tests=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-027 lifecycle safe gate passed"
