#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-018"
fault_output=${1:-"$result_root/faults.json"}
test_log=${2:-"$result_root/fault-tests.txt"}

mkdir -p "$result_root"
"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null

xcodebuild \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemory \
  -configuration Debug \
  -derivedDataPath "$repo_root/.build/DerivedData" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalMemoryUnitTests/ArchiveFileStoreTests \
  test 2>&1 | tee "$test_log"

"$repo_root/.build/DerivedData/Build/Products/Debug/Local Memory.app/Contents/MacOS/Local Memory" \
  --lm018-export-faults "$fault_output"

test -s "$fault_output"
rg -q 'Executed 9 tests, with 0 failures' "$test_log"
jq -e '
  .schemaVersion == 1 and
  .allInvariantsPassed == true and
  .pathTraversalRejected == true and
  .ownerOnlyDirectories == true and
  .ownerOnlyFiles == true and
  .requeuedLeasedJobs == 1 and
  (.boundaries | length) == 2 and
  (all(.boundaries[]; .invariantPassed and .searchableFramesAfterRecovery == 0)) and
  (.integrityCases | length) == 2 and
  (all(.integrityCases[]; .invariantPassed and .searchableFramesAfterRecovery == 0))
' "$fault_output" >/dev/null

echo "LM-018 atomic write/recovery gate passed"
