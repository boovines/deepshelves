#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root=${1:-"$repo_root/Benchmarks/Results/S3S4/$timestamp"}
derived_data="$repo_root/.build/LM007"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"
binary="$app_bundle/Contents/MacOS/Local Memory"
reference_dir=$(mktemp -d /tmp/deepshelves-lm007-reference.XXXXXX)
trap 'rm -rf "$reference_dir"' EXIT

mkdir -p "$result_root"
"$repo_root/Scripts/bootstrap-dependencies.sh" --offline "$repo_root/.dependency-cache" \
  >"$result_root/dependency-verification.log"
xcodegen generate --spec "$repo_root/project.yml"
xcodebuild build -quiet \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemoryApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  ENABLE_HARDENED_RUNTIME=YES
codesign --verify --deep --strict "$app_bundle"
codesign -d --entitlements :- "$app_bundle" >"$result_root/signed-entitlements.plist" 2>/dev/null

xcrun coremlcompiler compile \
  "$repo_root/.dependency-cache/models/mobileclip-s0/mobileclip_s0_image.mlpackage" \
  "$reference_dir" --platform macOS --deployment-target 15.0 >/dev/null
xcrun coremlcompiler compile \
  "$repo_root/.dependency-cache/models/mobileclip-s0/mobileclip_s0_text.mlpackage" \
  "$reference_dir" --platform macOS --deployment-target 15.0 >/dev/null

printf '%s\n' 'sandbox-exec profile: allow default; deny network*' >"$result_root/network-sandbox.txt"
/usr/bin/sandbox-exec -p '(version 1)(allow default)(deny network*)' \
  "$binary" --s3-s4-spike "$result_root" \
  "$reference_dir/mobileclip_s0_image.mlmodelc" \
  "$reference_dir/mobileclip_s0_text.mlmodelc" \
  >"$result_root/cli.stdout.log" \
  2>"$result_root/cli.stderr.log" &
benchmark_pid=$!

printf 'timestamp_epoch,cpu_percent,rss_kb\n' >"$result_root/resources.csv"
while kill -0 "$benchmark_pid" 2>/dev/null; do
  sample=$(ps -p "$benchmark_pid" -o %cpu=,rss= | awk '{$1=$1; print}')
  if [[ -n "$sample" ]]; then
    printf '%s,%s\n' "$(date +%s.%N)" "${sample/ /,}" >>"$result_root/resources.csv"
  fi
  sleep 0.1
done
wait "$benchmark_pid"
test -e "$result_root/s3-s4-complete.marker"

ruby -rjson - "$result_root/resources.csv" "$result_root/report.json" "$result_root/resource-summary.json" <<'RUBY'
rows = File.readlines(ARGV[0], chomp: true).drop(1).map do |line|
  fields = line.split(',')
  next unless fields.length == 3
  { timestamp: fields[0].to_f, cpu: fields[1].to_f, rss_mb: fields[2].to_f / 1024.0 }
end.compact.select { |row| row[:rss_mb] > 0 }
report = JSON.parse(File.read(ARGV[1]))
s4_start = report.fetch('exactVectorScan').fetch('startedAtEpoch')
s4_end = report.fetch('exactVectorScan').fetch('endedAtEpoch')
rss = rows.map { |row| row[:rss_mb] }
before_s4 = rows.select { |row| row[:timestamp] < s4_start }
during_s4 = rows.select { |row| row[:timestamp] >= s4_start && row[:timestamp] <= s4_end }
s4_baseline = before_s4.empty? ? (rss.min || 0.0) : before_s4.last[:rss_mb]
s4_peak = during_s4.map { |row| row[:rss_mb] }.max || s4_baseline
summary = {
  samples: rows.length,
  minimum_rss_mb: rss.min || 0.0,
  maximum_rss_mb: rss.max || 0.0,
  incremental_rss_mb: rss.empty? ? 0.0 : rss.max - rss.min,
  enrichment_maximum_rss_mb: before_s4.map { |row| row[:rss_mb] }.max || 0.0,
  vector_search_baseline_rss_mb: s4_baseline,
  vector_search_maximum_rss_mb: s4_peak,
  vector_search_incremental_rss_mb: [s4_peak - s4_baseline, 0.0].max,
  maximum_cpu_percent: rows.map { |row| row[:cpu] }.max || 0.0
}
File.write(ARGV[2], JSON.pretty_generate(summary) + "\n")
RUBY

source_manifest_sha256=$(
  {
    find "$repo_root/Apps" "$repo_root/Packages" "$repo_root/Tests" "$repo_root/Scripts" \
      -type f -print
    printf '%s\n' "$repo_root/project.yml"
  } | LC_ALL=C sort | while IFS= read -r source_path; do
    shasum -a 256 "$source_path"
  done | shasum -a 256 | awk '{print $1}'
)
corpus_sha256=$(
  find "$result_root/raw" -type f -print0 \
    | LC_ALL=C sort -z \
    | xargs -0 shasum -a 256 \
    | shasum -a 256 \
    | awk '{print $1}'
)

jq -n \
  --arg git_revision "$(git -C "$repo_root" rev-parse HEAD)" \
  --arg source_manifest_sha256 "$source_manifest_sha256" \
  --arg corpus_sha256 "$corpus_sha256" \
  --arg mac_model "$(sysctl -n hw.model)" \
  --argjson ram_bytes "$(sysctl -n hw.memsize)" \
  --arg os_version "$(sw_vers -productVersion)" \
  --arg os_build "$(sw_vers -buildVersion)" \
  --arg architecture "$(uname -m)" \
  --arg xcode_version "$(xcodebuild -version | tr '\n' ' ')" \
  '{git_revision:$git_revision,source_manifest_sha256:$source_manifest_sha256,corpus_sha256:$corpus_sha256,mac_model:$mac_model,ram_bytes:$ram_bytes,os_version:$os_version,os_build:$os_build,architecture:$architecture,xcode_version:$xcode_version,configuration:"Release",networkPolicy:"sandbox deny network*",modelSource:"pinned offline cache",modelLicenseScope:"private research evaluation only"}' \
  >"$result_root/environment.json"

"$repo_root/Scripts/check-s3-s4-vector-spike.sh" "$result_root"
printf '%s\n' "$result_root"
