#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-057"
fixture="$repo_root/Fixtures/LM057/browser-protection-matrix.json"
generated_fixture=$(mktemp "${TMPDIR:-/tmp}/deepshelves-lm057-fixture.XXXXXX")
trap 'rm -f "$generated_fixture"' EXIT

mkdir -p "$result_root"

assert_no_media_process() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-057 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during a source-isolated LM-057 gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -120 "$log" >&2
    return "$status"
  fi
}

assert_no_media_process

if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession' \
  "$repo_root/Tests/Unit/BrowserPrivacyProtectionTests.swift" \
  "$repo_root/Tests/Unit/BrowserContextAdapterTests.swift" \
  "$repo_root/Tests/Unit/PrivacyPolicyTests.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/BrowserPrivacyProtection.swift"; then
  echo "Quarantined media symbol entered LM-057 sources" >&2
  exit 1
fi

if rg -n 'requestFromUser|CGRequestScreenCaptureAccess|AXTrustedCheckOptionPrompt' \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/BrowserPrivacyProtection.swift"; then
  echo "Permission-health monitor must never request or prompt" >&2
  exit 1
fi

"$repo_root/scripts/generate-lm057-browser-protection-fixture.swift" "$generated_fixture"
cmp "$fixture" "$generated_fixture"
{
  jq -e '
    .schemaVersion == 1 and
    (.cases | length) == 200 and
    ([.cases[].id] | unique | length) == 200 and
    ([.cases[].browser] | unique | sort) == ["arcDia", "chrome", "edge", "firefox", "safari"] and
    ([.cases[] | select(.scenario == "healthy")] | length) == 40 and
    ([.cases[] | select(.scenario == "private")] | length) == 40 and
    ([.cases[] | select(.scenario == "urlUnavailable")] | length) == 40 and
    ([.cases[] | select(.scenario == "permissionRevoked")] | length) == 40 and
    ([.cases[] | select(.scenario == "versionChanged")] | length) == 40 and
    ([.cases[] | select(.expectedAllowed == false and .expectedIssue == null)] | length) == 0
  ' "$fixture" >/dev/null
  echo "fixture_sha256=$(shasum -a 256 "$fixture" | awk '{print $1}')"
  echo "browser_private_permission_version_cases=200"
  echo "supported_browser_count=5"
  echo "blocked_case_count=160"
  echo "expected_content_leak_count=0"
} | tee "$result_root/fixture-check.txt"

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/browser-privacy-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Debug \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:LocalMemoryUnitTests/BrowserPrivacyProtectionTests \
    -only-testing:LocalMemoryUnitTests/BrowserContextAdapterTests \
    -only-testing:LocalMemoryUnitTests/PrivacyPolicyTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/browser-privacy-tests.txt"
rg -q 'BrowserPrivacyProtectionTests.*passed' "$result_root/browser-privacy-tests.txt"
rg -q 'BrowserContextAdapterTests.*passed' "$result_root/browser-privacy-tests.txt"
rg -q 'PrivacyPolicyTests.*passed' "$result_root/browser-privacy-tests.txt"

{
  rg -Fq '.accessibilityIdentifier("privacy.privateBrowserHandling")' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq '.accessibilityIdentifier("privacy.refreshPermissionHealth")' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq '.accessibilityIdentifier("privacy.browserProtectionReason")' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  rg -Fq 'Browser capture pauses whenever a protected URL' \
    "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift"
  echo "private_browser_policy_control=passed"
  echo "permission_health_refresh_control=passed"
  echo "protected_context_reason_projection=passed"
  echo "ui_runtime=quarantined"
} | tee "$result_root/ui-static-audit.txt"

xcrun swift-format lint --strict \
  "$repo_root/Apps/LocalMemoryApp/PrivacySettings.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/BrowserContextAdapters.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/BrowserPrivacyProtection.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/PrivacyPolicy.swift" \
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/PrivacyPolicySettings.swift" \
  "$repo_root/Tests/Unit/BrowserPrivacyProtectionTests.swift" \
  "$repo_root/scripts/generate-lm057-browser-protection-fixture.swift" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"

git -C "$repo_root" diff --check
assert_no_media_process
{
  echo "lm057_media_symbol_scan=passed"
  echo "permission_prompt_source_scan=passed"
  echo "fixture_reproducibility=passed"
  echo "supported_browser_matrix=passed"
  echo "private_context_matrix=passed"
  echo "permission_revoke_matrix=passed"
  echo "browser_version_change_matrix=passed"
  echo "protected_url_unavailable_reasons=visible"
  echo "content_leak_count=0"
  echo "ui_static_accessibility_audit=passed"
  echo "ui_runtime_hardware_quarantine=honored"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-057 browser privacy safe gate passed"
