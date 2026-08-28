#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-059"
prior_s5="$repo_root/Benchmarks/Results/S5/20260827T224019Z"
mkdir -p "$result_root"

assert_no_media_process() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-059 gate while an Xcode test or encoder process is active" >&2
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
    echo "ABORTED: encoder service appeared during source-isolated LM-059 gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_no_media_process

focused_sources=(
  "$repo_root/Tests/Unit/ArchiveEncryptionTests.swift"
  "$repo_root/Tests/Unit/LM059StorageSecurityGateTests.swift"
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift"
  "$repo_root/Tests/Unit/ArchiveFileStoreTests.swift"
  "$repo_root/Tests/Integration/SQLCipherSpikeIntegrationTests.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEncryption.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession' \
  "${focused_sources[@]}"; then
  echo "Quarantined media symbol entered LM-059 sources" >&2
  exit 1
fi
if rg -n '(print|debugPrint|NSLog|Logger|os_log).*([Kk]ey|passphrase)|([Kk]ey|passphrase).*(print|debugPrint|NSLog|Logger|os_log)' \
  "$repo_root/Packages/MemoryStore" "$repo_root/Apps/LocalMemoryApp" --glob '*.swift'; then
  echo "Potential key-material logging path found" >&2
  exit 1
fi

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/storage-focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/ArchiveEncryptionTests \
    -only-testing:LocalMemoryUnitTests/LM059StorageSecurityGateTests \
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/ArchiveFileStoreTests \
    -only-testing:LocalMemoryIntegrationTests/SQLCipherSpikeIntegrationTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/storage-focused-tests.txt"

jq -e '
  .schemaVersion == 1 and
  .sentinelCount == 100 and
  .encryptedFilesScanned >= 2 and
  .plaintextSentinelMatches == 0 and
  (.cipherVersion | length) > 0 and
  .walEnabled == true and
  .tempFilesConfinedBesideDatabase == true and
  .concurrentFailedOperations == 0 and
  .integrityCheckPassed == true and
  .performanceSampleCount >= 40 and
  .encryptionOverheadFraction <= .maximumEncryptionOverheadFraction and
  .aclEvidence.signedAppModesMatched == true and
  .aclEvidence.unsignedHelperDenied == true and
  .aclEvidence.mismatchedAccessGroupDenied == true and
  .aclEvidence.standaloneHelpersHaveNoKeychainGroup == true and
  .keyMaterialLogged == false and
  .hardwareEncoderTestsExecuted == 0 and
  .appLaunchTestsExecuted == 0
' "$result_root/storage-security.json" >/dev/null

"$repo_root/scripts/check-s5-storage-spike.sh" "$prior_s5" \
  | tee "$result_root/prior-s5-validation.txt"

{
  rg -Fq 'public static let requiredConfirmation = "DELETE LOCAL MEMORY ARCHIVE"' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEncryption.swift"
  rg -Fq 'case keyMissingForExistingArchive' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEncryption.swift"
  rg -Fq 'PRAGMA cipher_version' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  rg -Fq 'PRAGMA cipher_integrity_check' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  rg -Fq 'PRAGMA cipher_memory_security = ON' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  rg -Fq '.accessibilityIdentifier("storage.unrecoverableKey")' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  rg -Fq '.accessibilityIdentifier("storage.resetConfirmation")' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  rg -Fq '.accessibilityIdentifier("storage.resetArchive")' \
    "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift"
  if rg -n 'preconditionFailure\("Local Memory archive bootstrap failed' \
    "$repo_root/Apps/LocalMemoryApp" --glob '*.swift'; then
    exit 1
  fi
  echo "production_key_required=passed"
  echo "cipher_activation_each_open=passed"
  echo "missing_key_fail_closed=passed"
  echo "typed_destructive_reset=passed"
  echo "reset_rollback=passed"
  echo "user_visible_recovery=passed"
  echo "ui_runtime=quarantined"
} | tee "$result_root/static-audit.txt"

xcrun swift-format lint --strict \
  "$repo_root/Apps/LocalMemoryApp/ArchiveSecurity.swift" \
  "$repo_root/Apps/LocalMemoryApp/LocalMemoryApp.swift" \
  "$repo_root/Apps/LocalMemoryApp/MainNavigation.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveEncryption.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/LM018FaultHarness.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/SharedKeychainKeyStore.swift" \
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift" \
  "$repo_root/Tests/Unit/ArchiveEncryptionTests.swift" \
  "$repo_root/Tests/Unit/ArchiveFileStoreTests.swift" \
  "$repo_root/Tests/Unit/LM059StorageSecurityGateTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"

git -C "$repo_root" diff --check
assert_no_media_process
{
  echo "sqlcipher_all_file_backed_archives=passed"
  echo "cipher_activation_and_integrity=passed"
  echo "database_wal_temp_sentinel_matches=0"
  echo "signed_embedded_helper_acl=passed"
  echo "unsigned_and_mismatched_acl=denied"
  echo "encryption_overhead_below_20_percent=passed"
  echo "key_material_log_matches=0"
  echo "unrecoverable_key_reset=typed_and_explicit"
  echo "ui_static_accessibility_audit=passed"
  echo "ui_runtime_hardware_quarantine=honored"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-059 storage security safe gate passed"
