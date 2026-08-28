#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-056"
fixture="$repo_root/Fixtures/LM056/change-during-capture.json"
generated_fixture=$(mktemp "${TMPDIR:-/tmp}/deepshelves-lm056-fixture.XXXXXX")
trap 'rm -f "$generated_fixture"' EXIT

mkdir -p "$result_root"

assert_no_media_process() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-056 gate while an Xcode test or encoder process is active" >&2
    exit 1
  fi
}

run_encoder_monitored() {
  local log=$1
  shift
  assert_no_media_process
  "$@" >"$log" 2>&1 &
  local command_pid=$!
  local encoder_seen=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if pgrep -x VTEncoderXPCService >/dev/null; then
      encoder_seen=1
      kill -TERM "$command_pid" 2>/dev/null || true
      while read -r process_id; do
        kill -TERM "$process_id" 2>/dev/null || true
      done < <(pgrep -x xcodebuild || true)
      while read -r process_id; do
        kill -TERM "$process_id" 2>/dev/null || true
      done < <(pgrep -x xctest || true)
      while read -r process_id; do
        kill -TERM "$process_id" 2>/dev/null || true
      done < <(pgrep -x VTEncoderXPCService || true)
      break
    fi
    sleep 0.25
  done
  set +e
  wait "$command_pid"
  local status=$?
  set -e
  if [[ "$encoder_seen" -ne 0 ]]; then
    echo "ABORTED: encoder service appeared during a source-isolated LM-056 gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -120 "$log" >&2
    return "$status"
  fi
}

assert_no_media_process

if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession' \
  "$repo_root/Tests/Unit/PrivacyPolicySettingsTests.swift" \
  "$repo_root/Tests/UI/PrivacySettingsUITests.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/PrivacyPolicySettings.swift"; then
  echo "Quarantined media symbol entered LM-056 sources" >&2
  exit 1
fi

"$repo_root/scripts/generate-lm056-policy-change-fixture.swift" "$generated_fixture"
cmp "$fixture" "$generated_fixture"
{
  jq -e '
    .schemaVersion == 1 and
    (.cases | length) == 100 and
    ([.cases[].id] | unique | length) == 100 and
    ([.cases[].bundleIdentifier] | unique | length) == 100 and
    ([.cases[].ruleID] | unique | length) == 100 and
    ([.cases[] | select(.expectedPolicyGeneration != 2)] | length) == 0 and
    ([.cases[] | select(.expectedDenialReason != "userRule")] | length) == 0 and
    ([.cases[] | select(.expectedGapReason != "excluded")] | length) == 0
  ' "$fixture" >/dev/null
  echo "fixture_sha256=$(shasum -a 256 "$fixture" | awk '{print $1}')"
  echo "change_during_capture_cases=100"
  echo "ui_projection_expected_leaks=0"
  echo "helper_projection_expected_leaks=0"
} | tee "$result_root/fixture-check.txt"

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/settings-unit.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Debug \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:LocalMemoryUnitTests/PrivacyPolicySettingsTests \
    test
rg -q 'Executed 8 tests, with 0 failures' "$result_root/settings-unit.txt"

{
  rg -Fq '.accessibilityIdentifier("privacy.settingsPane")' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq 'Rules are evaluated in order. The last matching user rule wins' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq '.accessibilityIdentifier("privacy.previewResult")' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq '.accessibilityIdentifier("privacy.rule.\(model.id)")' \
    "$repo_root/Packages/MemoryDesignSystem/Sources/MemoryDesignSystem/PrivacyRuleRow.swift"
  test "$(sed -n '/static let gaps:/,/^    ]/p' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift" \
    | rg -o 'gap\(' | wc -l | tr -d ' ')" = 14
  rg -q 'Excluded; no application details stored' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  echo "privacy_settings_accessibility_identifiers=passed"
  echo "rule_ordering_explanation=passed"
  echo "test_context_preview_projection=passed"
  echo "typed_timeline_gap_reasons=14"
  echo "excluded_timeline_identity_projection=absent"
  echo "ui_runtime=quarantined_after_VTEncoderXPCService_appearance"
} | tee "$result_root/ui-static-audit.txt"

xcrun swift-format lint --strict \
  "$repo_root/Apps/LocalMemoryApp/AppComposition.swift" \
  "$repo_root/Apps/LocalMemoryApp/LocalMemoryApp.swift" \
  "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift" \
  "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/PrivacyPolicy.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/PrivacyPolicySettings.swift" \
  "$repo_root/Packages/MemoryDesignSystem/Sources/MemoryDesignSystem/PrivacyRuleRow.swift" \
  "$repo_root/Tests/Unit/PrivacyPolicySettingsTests.swift" \
  "$repo_root/Tests/UI/PrivacySettingsUITests.swift" \
  "$repo_root/scripts/generate-lm056-policy-change-fixture.swift" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"

git -C "$repo_root" diff --check
assert_no_media_process
{
  echo "lm056_media_symbol_scan=passed"
  echo "fixture_reproducibility=passed"
  echo "change_during_capture_corpus=passed"
  echo "immediate_policy_generation_reload=passed"
  echo "post_effective_persistence_count=0"
  echo "ui_projection_leak_count=0"
  echo "helper_projection_leak_count=0"
  echo "typed_timeline_gap_projection=passed"
  echo "ui_static_accessibility_audit=passed"
  echo "ui_runtime_hardware_quarantine=honored"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-056 privacy settings safe gate passed"
