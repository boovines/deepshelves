#!/bin/bash
set -euo pipefail

result_root=${1:?usage: check-s3-s4-vector-spike.sh RESULT_ROOT}
report="$result_root/report.json"

for required in \
  "$report" \
  "$result_root/resource-summary.json" \
  "$result_root/environment.json" \
  "$result_root/network-sandbox.txt" \
  "$result_root/dependency-verification.log" \
  "$result_root/signed-entitlements.plist" \
  "$result_root/raw/visual-corpus.json" \
  "$result_root/raw/visual-queries.json" \
  "$result_root/raw/image-embeddings.f32" \
  "$result_root/raw/text-embeddings.f32" \
  "$result_root/raw/packaged-parity-image.f32" \
  "$result_root/raw/source-parity-image.f32" \
  "$result_root/raw/packaged-parity-text.f32" \
  "$result_root/raw/source-parity-text.f32" \
  "$result_root/raw/truncated-vector-fixture.f16"; do
  test -s "$required"
done

test "$(find "$result_root/raw/visual-frames" -type f -name 'image-*.png' | wc -l | tr -d ' ')" = 500
test "$(jq 'length' "$result_root/raw/visual-corpus.json")" = 500
test "$(jq 'length' "$result_root/raw/visual-queries.json")" = 100
test "$(stat -f '%z' "$result_root/raw/image-embeddings.f32")" = 1024000
test "$(stat -f '%z' "$result_root/raw/text-embeddings.f32")" = 204800
for parity_vector in "$result_root"/raw/*-parity-*.f32; do
  test "$(stat -f '%z' "$parity_vector")" = 2048
done

jq -e '
  .schemaVersion == 1 and
  .parity.imageCosineSimilarity >= 0.999 and
  .parity.textCosineSimilarity >= 0.999 and
  .inference.imageCount == 500 and
  .inference.textQueryCount == 100 and
  .inference.imageP95Milliseconds < 100 and
  .inference.textP95Milliseconds < 50 and
  .inference.visualRecallAt10 >= 0.75 and
  .inference.captureTimerIntervalsOver100Milliseconds == 0 and
  .inference.maximumConcurrentInferenceJobs == 1 and
  .packaging.artifactCount == .packaging.verifiedArtifactCount and
  .packaging.bundledFootprintBytes < 262144000 and
  .packaging.runtimeDownloadAllowed == false and
  .exactVectorScan.vectorCount == 1000000 and
  .exactVectorScan.dimension == 512 and
  .exactVectorScan.fileBytes == 1024000128 and
  .exactVectorScan.unfilteredSampleCount >= 20 and
  .exactVectorScan.unfilteredP95Milliseconds < 750 and
  .exactVectorScan.unfilteredP99Milliseconds < 1000 and
  .exactVectorScan.filteredCandidateCount == 100000 and
  .exactVectorScan.filteredP95Milliseconds < 250 and
  .exactVectorScan.maximumScalarScoreError <= 0.001 and
  .exactVectorScan.stableOrderingMatched and
  .exactVectorScan.truncatedFileDetectedBeforeResults
' "$report" >/dev/null

jq -e '
  .enrichment_maximum_rss_mb < 750 and
  .vector_search_incremental_rss_mb < 500 and
  .samples >= 5
' \
  "$result_root/resource-summary.json" >/dev/null
jq -e '
  (.git_revision | length) == 40 and
  (.source_manifest_sha256 | length) == 64 and
  (.corpus_sha256 | length) == 64 and
  .configuration == "Release" and
  .networkPolicy == "sandbox deny network*" and
  .modelSource == "pinned offline cache"
' "$result_root/environment.json" >/dev/null

if rg -n --glob '*.swift' 'URLSession|NWConnection|NWListener|https?://' \
  "$PWD/Packages/MemoryEnrichment/Sources"; then
  printf 'Remote inference or URL literal found in MemoryEnrichment shipping source\n' >&2
  exit 1
fi

printf 'S3/S4 model and exact-vector gates passed: %s\n' "$result_root"
