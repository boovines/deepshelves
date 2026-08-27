#!/bin/bash
set -euo pipefail

result_root=${1:?usage: check-s2-context-spike.sh RESULT_ROOT}
report="$result_root/context-matrix.json"

for required in \
  "$report" \
  "$result_root/environment.json" \
  "$result_root/signed-entitlements.plist" \
  "$result_root/raw/fixture-catalog.json" \
  "$result_root/raw/live-ax-probes.json" \
  "$result_root/raw/ocr-observations.jsonl"; do
  test -s "$required"
done

test "$(find "$result_root/raw/ocr" -type f -name '*.png' | wc -l | tr -d ' ')" = 200
test "$(wc -l <"$result_root/raw/ocr-observations.jsonl" | tr -d ' ')" = 200

jq -e '
  .schemaVersion == 1 and
  .ax.fixtureCount == 250 and
  .ax.usefulRate >= 0.80 and
  .ax.p95TraversalMilliseconds < 50 and
  .ax.liveProbeCount >= 20 and
  .ax.liveUsefulCount >= 1 and
  .ax.liveTimeoutCount == 0 and
  .ax.liveP95Milliseconds < 50 and
  .ax.captureThreadBlockingCount == 0 and
  .ocr.fixtureCount == 200 and
  .ocr.highContrastFixtureCount >= 150 and
  .ocr.highContrastWordRecall >= 0.90 and
  .ocr.fullCorpusWordRecall >= 0.82 and
  .merge.duplicateNormalizedTokenRate < 0.03 and
  .merge.uniqueGroundTruthLossRate < 0.01 and
  .browser.fixtureCount >= 500 and
  .browser.hostDetectionAccuracy >= 0.98 and
  .browser.privateFixtureCount == .browser.privateSuppressionCount and
  .browser.inspectionFailureWithRuleCount == .browser.suppressedWithinOneFrameCount and
  .privacy.fixtureCount >= 190 and
  .privacy.backgroundSentinelFixtureCount >= 50 and
  .privacy.persistedProhibitedArtifactCount == 0 and
  .privacy.mediaLeakCount == 0 and
  .privacy.thumbnailLeakCount == 0 and
  .privacy.textLeakCount == 0 and
  .privacy.titleLeakCount == 0 and
  .privacy.urlLeakCount == 0 and
  .privacy.vectorLeakCount == 0 and
  .privacy.cacheLeakCount == 0 and
  .privacy.logLeakCount == 0 and
  (.contextMatrix | length) == 15 and
  ([.contextMatrix[].contextID] | unique | length) == 15
' "$report" >/dev/null

jq -e '
  (.git_revision | length) == 40 and
  (.source_manifest_sha256 | length) == 64 and
  (.corpus_sha256 | length) == 64 and
  .configuration == "Release" and
  .liveProbeScope == "DeepShelves synthetic window only"
' "$result_root/environment.json" >/dev/null

if find "$result_root" -path "$result_root/raw" -prune -o -type f -print0 \
  | xargs -0 rg -l 'S2_(FORBIDDEN|BACKGROUND|SECURE_VALUE)' >/dev/null 2>&1; then
  printf 'Prohibited fixture sentinel leaked into derivative output\n' >&2
  exit 1
fi

printf 'S2 context spike gates passed: %s\n' "$result_root"
