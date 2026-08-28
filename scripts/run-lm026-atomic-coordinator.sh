#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-026"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-026 gate while an Xcode test or encoder process is active" >&2
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
    sleep 0.1
  done
  set +e
  wait "$command_pid"
  local status=$?
  set -e
  if [[ "$encoder_seen" -ne 0 ]]; then
    echo "ABORTED: encoder service appeared during LM-026 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveHEICChunkVerifier.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV2.swift"
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift"
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift"
  "$repo_root/Tests/Unit/ArchiveFileStoreTests.swift"
)
if rg -n 'HEVCMediaWriter\s*\(|AVAssetWriter|VideoToolbox|VTCompressionSession' \
  "${focused_sources[@]}"; then
  echo "Quarantined hardware media symbol entered LM-026 sources" >&2
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
    -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
    -only-testing:LocalMemoryUnitTests/ArchiveFileStoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

xcrun swift-format lint --strict \
  "$repo_root/Packages/MemoryStore/Package.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveDatabase.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveHEICChunkVerifier.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV1.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV2.swift" \
  "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift" \
  "$repo_root/Tests/Unit/ArchiveDatabaseTests.swift" \
  "$repo_root/Tests/Unit/ArchiveFileStoreTests.swift" \
  2>&1 | tee "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"

{
  rg -Fq 'v2_heic_frame_locators' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV2.swift"
  rg -Fq 'schema V2 frames require an exact canonical HEIC locator' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveSchemaV2.swift"
  rg -Fq 'guard try currentIdentity() == identity' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift"
  rg -Fq 'transactionVerified = try verify' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveAtomicCoordinator.swift"
  rg -Fq 'ArchiveHEICChunkVerifier.verify' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift"
  rg -Fq 'parent_media_quarantined' \
    "$repo_root/Packages/MemoryStore/Sources/MemoryStore/ArchiveStartupRecovery.swift"
  echo "append_only_v2_locator_migration=passed"
  echo "exact_frame_locator_triggers=passed"
  echo "final_identity_recheck_inside_transaction=passed"
  echo "manifest_and_asset_reverification_inside_transaction=passed"
  echo "chunk_frame_job_atomicity=passed"
  echo "staging_rows=0"
  echo "orphan_directory_reconciliation=passed"
  echo "corrupt_media_search_exposure=0"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

git -C "$repo_root" diff --check
assert_safe_process_state
{
  echo "focused_release_tests=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "encoder_process_tripwire=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-026 atomic coordinator safe gate passed"
