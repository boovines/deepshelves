#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-044"
fixture="$repo_root/Fixtures/LM044/timeline-24-hour.json"
expected_fixture_hash="ebdabc6f41d55df2a796b56814f16d78555af015904e1b34883c6ffdccb57d2a"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-044 gate while a test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during LM-044 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -200 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state
focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveTimelineQuery.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveRecordingGapStore.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Tests/Unit/ArchiveTimelineQueryTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-044 sources" >&2
  exit 1
fi

actual_fixture_hash=$(shasum -a 256 "$fixture" | awk '{print $1}')
[[ "$actual_fixture_hash" == "$expected_fixture_hash" ]]
rg -Fq "$expected_fixture_hash" "$repo_root/Tests/Unit/ArchiveTimelineQueryTests.swift"
jq -e '
  .schemaVersion == 1
  and .durationSeconds == 86400
  and (.frames | length) == 4
  and (.gaps | length) == 3
  and .expectedGapReasons == ["sleep", "excluded", "processStopped"]
  and .expectedGapDurationsSeconds == [1200, 600, 1800]
' "$fixture" >/dev/null

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedDataLM044" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/ArchiveTimelineQueryTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"
[[ $(rg -c 'Test Case .* passed' "$result_root/focused-tests.txt") -eq 6 ]]

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-044 sources." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" --binaries \
  2>&1 | tee "$result_root/dependencies.txt"

query_source="$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveTimelineQuery.swift"
{
  rg -Fq "frames.captured_at >= ? AND frames.captured_at < ?" "$query_source"
  rg -Fq "frames.visual_state = 'ready'" "$query_source"
  rg -Fq "media_chunks.state = 'ready'" "$query_source"
  rg -Fq "merged_text_records.state = 'ready'" "$query_source"
  rg -Fq "started_at < ?" "$query_source"
  rg -Fq "ended_at > ?" "$query_source"
  rg -Fq 'max(startedAt, interval.start)' "$query_source"
  rg -Fq 'min(endedAt, interval.end)' "$query_source"
  echo "frozen_fixture_sha256=$actual_fixture_hash"
  echo "half_open_frame_pagination=passed"
  echo "calendar_dst_day_pagination=passed"
  echo "fixed_zoom_pagination=passed"
  echo "typed_gap_clipping=passed"
  echo "approved_transition_lookback=passed"
  echo "ready_only_projection=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "apple_imageio_runtime_executed=0"
  echo "application_launches_executed=0"
} | tee "$result_root/static-audit.txt"

perl -pi -e 's/[ \t]+$//' \
  "$result_root/focused-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' \
  "$result_root/focused-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "frozen_24_hour_fixture=passed"
  echo "exact_frame_gap_transition_marker_order=passed"
  echo "exact_gap_elapsed_durations=passed"
  echo "spring_fall_dst_days=passed"
  echo "sleep_excluded_stopped_gaps_explicit=passed"
  echo "day_and_zoom_pagination=passed"
  echo "suppressed_projection_absence=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-044 timeline interval query gate passed without media or app runtime"
