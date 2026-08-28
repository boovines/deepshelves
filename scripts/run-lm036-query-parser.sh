#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-036"
fixture="$repo_root/Fixtures/LM036/query-parse-goldens.json"
generated_fixture=$(mktemp "${TMPDIR:-/tmp}/deepshelves-lm036-fixture.XXXXXX")
trap 'rm -f "$generated_fixture"' EXIT

mkdir -p "$result_root"

if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
  || pgrep -f '(^|/)LocalMemoryIntegrationTests( |$)' >/dev/null; then
  echo "Refusing LM-036 gate while an Xcode test process is active" >&2
  exit 1
fi

if rg -n 'AVFoundation|VideoToolbox|AVAssetWriter|HEVCMediaWriter' \
  "$repo_root/Packages/MemorySearch"; then
  echo "Media encoder dependency entered the Foundation-only MemorySearch package" >&2
  exit 1
fi
if rg -n 'HEVCMediaWriter\s*\(' "$repo_root/Tests/Unit"; then
  echo "Unit gate can construct the quarantined hardware writer" >&2
  exit 1
fi

"$repo_root/scripts/generate-lm036-query-fixtures.swift" "$generated_fixture"
cmp "$fixture" "$generated_fixture"
{
  jq -e '
    .schemaVersion == 1 and
    (.cases | length) == 100 and
    ([.cases[].id] | unique | length) == 100 and
    ([.cases[].id | split("-")[0]] | group_by(.) | all(length == 10))
  ' "$fixture" >/dev/null
  echo "fixture_sha256=$(shasum -a 256 "$fixture" | awk '{print $1}')"
  echo "query_goldens=100"
  echo "hidden_filter_property=covered"
} | tee "$result_root/fixture-check.txt"

swift test --package-path "$repo_root/Packages/MemorySearch" \
  2>&1 | tee "$result_root/parser-tests.txt"

xcrun swift-format lint --strict \
  "$repo_root/Packages/MemorySearch/Sources/MemorySearch/SearchQueryParser.swift" \
  "$repo_root/Packages/MemorySearch/Tests/MemorySearchTests/SearchQueryParserTests.swift" \
  "$repo_root/scripts/generate-lm036-query-fixtures.swift" \
  2>&1 | tee "$result_root/swift-format.txt"

"$repo_root/scripts/check-contracts.sh" 2>&1 | tee "$result_root/contracts.txt"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
"$repo_root/scripts/build-release.sh" 2>&1 | tee "$result_root/release-build.txt"

git -C "$repo_root" diff --check
{
  echo "memory_search_media_scan=passed"
  echo "unit_writer_construction_scan=passed"
  echo "fixture_reproducibility=passed"
  echo "parser_package_tests=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "whitespace=passed"
} | tee "$result_root/story-gate.txt"

echo "LM-036 deterministic query parser gate passed"
