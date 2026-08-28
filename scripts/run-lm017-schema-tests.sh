#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-017"
schema_output=${1:-"$result_root/schema.sql"}
test_log=${2:-"$result_root/schema-tests.txt"}

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
  -only-testing:LocalMemoryUnitTests/ArchiveDatabaseTests \
  test 2>&1 | tee "$test_log"

"$repo_root/.build/DerivedData/Build/Products/Debug/Local Memory.app/Contents/MacOS/Local Memory" \
  --lm017-export-schema "$schema_output"

test -s "$schema_output"
rg -q 'Executed 7 tests, with 0 failures' "$test_log"
rg -q 'CREATE VIRTUAL TABLE frame_fts USING fts5' "$schema_output"
rg -q "content='frames'" "$schema_output"
if rg -qi 'CREATE TRIGGER' "$schema_output"; then
  echo "frame_fts maintenance must remain explicit; triggers are forbidden" >&2
  exit 1
fi

for table in \
  archive_meta media_chunks frames text_spans frame_fts artifacts vector_offsets \
  activity_intervals processing_jobs policy_decisions access_policies \
  deletion_tombstones audit_events; do
  rg -q "CREATE (VIRTUAL )?TABLE $table" "$schema_output"
done

echo "LM-017 schema/migration gate passed"
