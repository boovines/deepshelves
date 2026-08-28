#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-028"
temporary_root=$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-lm028.XXXXXX")
watcher_pid=""

cleanup() {
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  if [[ -d "$temporary_root" ]]; then
    find "$temporary_root" -type f -delete
    find "$temporary_root" -depth -type d -exec rmdir {} \; 2>/dev/null || true
  fi
}
trap cleanup EXIT

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-028 safe gate while an Xcode test or encoder process is active" >&2
    exit 90
  fi
}

start_tripwire() {
  assert_safe_process_state
  (
    while true; do
      if pgrep -x VTEncoderXPCService >/dev/null; then
        pkill -x VTEncoderXPCService 2>/dev/null || true
        printf '%s\n' "VideoToolbox encoder service appeared" \
          >"$result_root/ENCODER-TRIPWIRE-FAILED"
        exit 91
      fi
      sleep 0.05
    done
  ) &
  watcher_pid=$!
}

stop_tripwire() {
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  watcher_pid=""
  test ! -e "$result_root/ENCODER-TRIPWIRE-FAILED"
  test -z "$(pgrep -x VTEncoderXPCService || true)"
}

run_monitored() {
  local log=$1
  shift
  start_tripwire
  set +e
  "$@" >"$log" 2>&1
  local status=$?
  set -e
  stop_tripwire
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

mkdir -p "$result_root"
find "$result_root" -maxdepth 1 -name 'ENCODER-TRIPWIRE-FAILED' -delete
assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureSoakModel.swift"
  "$repo_root/Packages/MemoryCapture/Sources/LM028SoakHarness/main.swift"
  "$repo_root/Tests/Unit/CaptureSoakModelTests.swift"
  "$repo_root/scripts/measure-lm028-software-decode.py"
)
if rg -n 'ImageIOHEICFrameEncoder\s*\(|CGImageDestinationCreateWithData|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox' \
  "${focused_sources[@]}"; then
  echo "Quarantined Apple or hardware codec path entered LM-028 executable tests" >&2
  exit 1
fi

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_monitored "$result_root/focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/CaptureSoakModelTests \
    -only-testing:LocalMemoryUnitTests/SoftwareHEICCodecTests \
    -only-testing:LocalMemoryUnitTests/WindowCaptureEpochTests \
    -only-testing:LocalMemoryUnitTests/ForegroundWindowResolverTests \
    -only-testing:LocalMemoryUnitTests/PrivacyPolicyTests \
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/ArchiveFileStoreTests \
    -only-testing:LocalMemoryUnitTests/AppLifecycleTests \
    -only-testing:LocalMemoryUnitTests/ScreenCaptureRuntimeTests \
    -only-testing:LocalMemoryIntegrationTests/CaptureMediaIntegrationTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

run_monitored "$result_root/software-decode-run.txt" \
  python3 "$repo_root/scripts/measure-lm028-software-decode.py" \
    "$repo_root/Fixtures/LM028" \
    "$result_root/software-decode.json"
mean_heic_bytes=$(jq -r '.weightedCorpus.projectedMeanBytesAt1920x1080' \
  "$result_root/software-decode.json")

soak_output="$temporary_root/soak-model.json"
run_monitored "$result_root/soak-harness.txt" \
  swift run -c release \
    --package-path "$repo_root/Packages/MemoryCapture" \
    LM028SoakHarness "$soak_output" "$mean_heic_bytes"
mv -f "$soak_output" "$result_root/soak-model.json"

jq -e '
  .office.simulatedDurationSeconds == 28800 and
  .office.candidateCount == 57600 and
  .office.queuePeakCount <= 4 and
  .office.queueFinalCount == 0 and
  .office.prohibitedSentinelPersistedCount == 0 and
  .office.corruptPublishedArtifactCount == 0 and
  .office.orphanPublishedArtifactCount == 0 and
  .office.projectedThirtyDayBytes < 20000000000 and
  .accelerated.simulatedDurationSeconds == 259200 and
  .accelerated.candidateCount == 518400 and
  .accelerated.queuePeakCount <= 4 and
  .accelerated.queueFinalCount == 0 and
  .accelerated.prohibitedSentinelPersistedCount == 0 and
  .accelerated.corruptPublishedArtifactCount == 0 and
  .accelerated.orphanPublishedArtifactCount == 0
' "$result_root/soak-model.json" >/dev/null
jq -e '
  .encoderInvocations == 0 and
  .videoToolboxInvocations == 0 and
  .maximumResidentBytes < 750000000 and
  ([.corpus[].p95Milliseconds] | max) < 200 and
  ([.corpus[].iterations] | all(. == 30))
' "$result_root/software-decode.json" >/dev/null

xcrun swift-format lint --strict \
  "$repo_root/Packages/MemoryCapture/Package.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureSoakModel.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/LM028SoakHarness/main.swift" \
  "$repo_root/Tests/Unit/CaptureSoakModelTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"
python3 -c 'import ast, pathlib, sys; ast.parse(pathlib.Path(sys.argv[1]).read_text())' \
  "$repo_root/scripts/measure-lm028-software-decode.py"

run_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

{
  rg -Fq 'SCContentFilter(desktopIndependentWindow:' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/EpochCapturePipeline.swift"
  if rg -n 'SCContentFilter\((display:|excludingWindows:|includingApplications:)' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/EpochCapturePipeline.swift"; then
    exit 1
  fi
  rg -Fq 'prohibitedSentinelPersistedCount: 0' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureSoakModel.swift"
  rg -Fq 'PrivacyPersistenceGate.project' \
    "$repo_root/Tests/Unit/PrivacyPolicyTests.swift"
  rg -Fq 'SafeFakeHEICEncoder' \
    "$repo_root/Tests/Integration/CaptureMediaIntegrationTests.swift"
  rg -Fq 'encoder: any HEICFrameEncoding' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"
  if rg -n 'encoder: any HEICFrameEncoding = ImageIOHEICFrameEncoder' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"; then
    exit 1
  fi
  rg -Fq 'frameEncoder: any HEICFrameEncoding = QuarantinedHEICFrameEncoder()' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureSpikeRunner.swift"
  rg -Fq 'let codec = try SoftwareHEICCodec()' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureDecodeBenchmark.swift"
  if rg -n 'import ImageIO|CGImageSourceCreate' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/CaptureDecodeBenchmark.swift"; then
    exit 1
  fi
  test ! -e "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEVCMediaWriter.swift"
  echo "foreground_window_filter_only=passed"
  echo "privacy_denial_projection=passed"
  echo "stale_epoch_rejection=passed"
  echo "bounded_queue_capacity=4"
  echo "fake_encoder_boundary_only=passed"
  echo "production_encoder_requires_explicit_injection=passed"
  echo "production_capture_requires_explicit_software_codec=passed"
  echo "actual_app_launches=0"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_tests_executed=0"
  echo "software_heic_encode_decode=passed"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" \
  "$result_root/red.txt" \
  "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" \
  "$result_root/red.txt" \
  "$result_root/release-build.txt"

jq -n \
  --slurpfile soak "$result_root/soak-model.json" \
  --slurpfile decode "$result_root/software-decode.json" \
  '{
    story: "LM-028",
    status: "blocked",
    safeSuite: "passed",
    officeModel: $soak[0].office,
    acceleratedModel: $soak[0].accelerated,
    softwareDecode: $decode[0],
    actualWallClockOfficeSoakExecuted: false,
    productionImageIOExecuted: false,
    appRuntimeExecuted: false,
    hardwareEncoderTestsExecuted: 0,
    remainingGate: "Run the required real eight-hour foreground-window production capture/decode/resource soak with the now-proven software-only codec beneath the encoder-service tripwire."
  }' >"$result_root/report.json"

git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "focused_release_tests=passed"
  echo "eight_hour_synthetic_office_model=passed"
  echo "seventy_two_hour_accelerated_model=passed"
  echo "software_decode_p95=passed"
  echo "projected_thirty_day_storage=passed"
  echo "foreground_privacy_and_fault_suite=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "encoder_process_tripwire=passed"
  echo "actual_eight_hour_production_soak=blocked"
} | tee "$result_root/story-gate.txt"

echo "LM-028 safe suite passed; actual production codec soak remains technically blocked"
