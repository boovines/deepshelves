#!/bin/bash
set -euo pipefail

result_root=${1:?usage: check-s1-capture-spike.sh RESULT_ROOT}
active_report="$result_root/active/report.json"
static_report="$result_root/static/report.json"

for required in \
  "$active_report" \
  "$static_report" \
  "$result_root/active/resource-summary.json" \
  "$result_root/static/resource-summary.json" \
  "$result_root/active/storage-summary.json" \
  "$result_root/static/storage-summary.json" \
  "$result_root/decode-summary.json" \
  "$result_root/crash-integrity.json" \
  "$result_root/environment.json"; do
  test -s "$required"
done

jq -e '
  .framesAccepted > 0 and
  .staleOrPolicyFramesRejected > 0 and
  .contaminationFrames == 0 and
  (.writerErrors | length) == 0 and
  .eligibleFocusTransitions >= 500 and
  .correctWithinOneSecondTransitions >= (.eligibleFocusTransitions * 0.99) and
  .unresolvedOrExcludedTransitions >= 10 and
  .sleepTransitions > 0 and
  .wakeTransitions > 0 and
  (.filterUpdateLatenciesMilliseconds | max) < 1000 and
  (.chunks | length) == (.mediaPaths | length) and
  ([.chunks[].path] | unique | length) == (.chunks | length)
' "$active_report" >/dev/null

jq -e '
  .framesAccepted > 0 and
  .contaminationFrames == 0 and
  (.writerErrors | length) == 0
' "$static_report" >/dev/null

jq -e '.mean_cpu_percent < 6 and .p95_cpu_percent < 12 and .maximum_rss_mb < 500' \
  "$result_root/active/resource-summary.json" >/dev/null
jq -e '.mean_cpu_percent < 1.5 and .maximum_rss_mb < 500' \
  "$result_root/static/resource-summary.json" >/dev/null
jq -e '.storage_mb_per_hour < 75' "$result_root/active/storage-summary.json" >/dev/null
jq -e '.storage_mb_per_hour < 10' "$result_root/static/storage-summary.json" >/dev/null
jq -e '.p95Milliseconds < 150 and .p99Milliseconds < 300' "$result_root/decode-summary.json" >/dev/null
jq -e '
  (.git_revision | length) == 40 and
  (.source_manifest_sha256 | length) == 64 and
  (.corpus_sha256 | length) == 64 and
  .configuration == "Release"
' "$result_root/environment.json" >/dev/null
jq -e '
  .required_count == 30 and
  (.results | length) == 30 and
  ([.results[].playable] | all) and
  ([.results[].codec] | all(. == "hevc"))
' "$result_root/crash-integrity.json" >/dev/null

while IFS= read -r media_path; do
  test -s "$media_path"
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$media_path")
  test "$codec" = hevc
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$media_path")
  awk -v duration="$duration" 'BEGIN { exit !(duration <= 30.0) }'
done < <(jq -r '.mediaPaths[]' "$active_report" "$static_report")

printf 'S1 capture spike gates passed: %s\n' "$result_root"
