#!/bin/bash
set -euo pipefail

root="${1:?usage: check-s5-storage-spike.sh RESULTS_ROOT}"
report="$root/s5-report.json"
environment="$root/environment.json"
database="$root/raw/database/archive.sqlite3"

[[ -f "$report" ]]
[[ -f "$environment" ]]
[[ -f "$database" ]]
jq -e '
  .schemaVersion == 1 and
  .keychain.keyByteCount == 32 and
  .keychain.appModeStatus == 0 and
  .keychain.cliModeStatus == 0 and
  .keychain.mcpModeStatus == 0 and
  .keychain.appModeHashMatched == true and
  .keychain.cliModeHashMatched == true and
  .keychain.mcpModeHashMatched == true and
  .keychain.unsignedHelperDenied == true and
  .keychain.mismatchedAccessGroupDenied == true and
  .encryption.sentinelCount == 100 and
  .encryption.plaintextMatchesBeforeDeletion == 0 and
  .encryption.walEnabled == true and
  .encryption.concurrentWorkload.roleCount == 5 and
  .encryption.concurrentWorkload.failedOperationCount == 0 and
  .encryption.concurrentWorkload.integrityCheckPassed == true and
  .performance.sampleCount >= 40 and
  .performance.encryptionOverheadFraction < 0.20 and
  .faultInjection.crashPointCount == 10000 and
  .faultInjection.consistentRecoveryCount == 10000 and
  .faultInjection.searchableMissingMediaCount == 0 and
  .faultInjection.orphanReadyMediaCount == 0 and
  .processCrashes.forcedTerminationCount == 4 and
  .processCrashes.consistentRecoveryCount == 4 and
  .deletion.plaintextMatchesAfterDeletion == 0 and
  .deletion.databaseRowsAfterDeletion == 0 and
  .deletion.seededMediaDecodedBeforeDeletion == true and
  .deletion.seededMediaAbsentAfterDeletion == true and
  .deletion.mediaFilesDecodedAfterDeletion == 0 and
  .deletion.mediaDecodeSentinelCount == 0 and
  .deletion.helperProjectionSentinelCount == 0
' "$report" >/dev/null

if [[ "$(head -c 16 "$database")" == "SQLite format 3" ]]; then
    echo "Encrypted database exposes the plaintext SQLite header" >&2
    exit 1
fi
if rg -a -l 'LM008-S5-SENTINEL' "$root" >/dev/null; then
    echo "Deleted sentinel remains in S5 evidence" >&2
    exit 1
fi
jq -e '.configuration == "Release" and (.keychainScope | contains("unsigned"))' \
    "$environment" >/dev/null
if rg -i 'passphrase|secretKey|rawKey|keyData' "$root" -g '*.json' -g '*.log' >/dev/null; then
    echo "S5 logs/report contain a forbidden key-material field" >&2
    exit 1
fi

echo "S5 SQLCipher, Keychain, crash, performance, and deletion gates passed: $root"
