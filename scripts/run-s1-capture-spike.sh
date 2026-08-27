#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
active_seconds=${1:-3600}
static_seconds=${2:-300}
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root=${3:-"$repo_root/Benchmarks/Results/S1/$timestamp"}
derived_data="$repo_root/.build/LM005"
app_binary="$derived_data/Build/Products/Release/Local Memory.app/Contents/MacOS/Local Memory"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"

mkdir -p "$result_root"
xcodegen generate --spec "$repo_root/project.yml"
xcodebuild build -quiet \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemoryApp \
  -configuration Release \
  -destination 'platform=macOS' \
  -derivedDataPath "$derived_data" \
  ENABLE_HARDENED_RUNTIME=YES

run_mode() {
  local mode=$1
  local seconds=$2
  local mode_dir="$result_root/$mode"
  local launcher_pid
  mkdir -p "$mode_dir"
  if [[ "$mode" == "static" ]]; then
    open -W -n "$app_bundle" --args \
      --capture-spike "$mode_dir" --capture-spike-duration "$seconds" --capture-spike-static \
      >"$mode_dir/app.stdout.log" \
      2>"$mode_dir/app.stderr.log" &
  else
    open -W -n "$app_bundle" --args \
      --capture-spike "$mode_dir" --capture-spike-duration "$seconds" \
      >"$mode_dir/app.stdout.log" \
      2>"$mode_dir/app.stderr.log" &
  fi
  launcher_pid=$!
  local app_pid=""
  for _ in $(seq 1 100); do
    app_pid=$(ps ax -o pid=,command= | awk -v needle="$mode_dir" '
      index($0, needle) > 0 && index($0, "Local Memory.app/Contents/MacOS/Local Memory") > 0 {pid=$1}
      END {if (pid) print pid}
    ')
    [[ -n "$app_pid" ]] && break
    sleep 0.1
  done
  if [[ -z "$app_pid" ]]; then
    wait "$launcher_pid" || true
    printf 'Unable to resolve signed app process for %s mode\n' "$mode" >&2
    return 1
  fi
  printf 'timestamp_epoch,cpu_percent,rss_kb\n' >"$mode_dir/resources.csv"
  (
    while kill -0 "$app_pid" 2>/dev/null && [[ ! -e "$mode_dir/capture-complete.marker" ]]; do
      local sample
      sample=$(ps -p "$app_pid" -o %cpu=,rss= | awk '{$1=$1; print}')
      if [[ -n "$sample" ]]; then
        printf '%s,%s\n' "$(date +%s)" "${sample/ /,}" >>"$mode_dir/resources.csv"
      fi
      sleep 1
    done
  ) &
  local sampler_pid=$!
  wait "$launcher_pid"
  wait "$sampler_pid" || true

  ruby -rjson - "$mode_dir/resources.csv" "$mode_dir/resource-summary.json" <<'RUBY'
rows = File.readlines(ARGV[0], chomp: true).drop(1).map do |line|
  fields = line.split(',')
  next unless fields.length == 3
  { cpu: fields[1].to_f, rss_mb: fields[2].to_f / 1024.0 }
end.compact
settled = rows.drop([10, rows.length].min)
settled = rows if settled.empty?
percentile = ->(values, quantile) do
  sorted = values.sort
  sorted.empty? ? 0.0 : sorted[[(sorted.length * quantile).ceil - 1, 0].max]
end
cpu = settled.map { |row| row[:cpu] }
rss = rows.map { |row| row[:rss_mb] }
summary = {
  samples: rows.length,
  settled_samples: settled.length,
  mean_cpu_percent: cpu.empty? ? 0.0 : cpu.sum / cpu.length,
  p95_cpu_percent: percentile.call(cpu, 0.95),
  maximum_rss_mb: rss.max || 0.0
}
File.write(ARGV[1], JSON.pretty_generate(summary) + "\n")
RUBY

  local media_bytes
  media_bytes=$(find "$mode_dir" -maxdepth 1 -name '*.mov' -type f -exec stat -f '%z' {} \; | awk '{sum += $1} END {print sum + 0}')
  jq -n \
    --arg mode "$mode" \
    --argjson duration_seconds "$seconds" \
    --argjson media_bytes "$media_bytes" \
    '{mode:$mode,duration_seconds:$duration_seconds,media_bytes:$media_bytes,storage_mb_per_hour:(($media_bytes / 1048576) * (3600 / $duration_seconds))}' \
    >"$mode_dir/storage-summary.json"
}

run_mode active "$active_seconds"
run_mode static "$static_seconds"

cp "$result_root/active/decode-summary.json" "$result_root/decode-summary.json"
"$repo_root/scripts/run-s1-crash-integrity.sh" "${S1_CRASH_COUNT:-30}" "$result_root"

source_manifest_sha256=$(
  {
    find "$repo_root/Apps" "$repo_root/Packages" "$repo_root/Tests" "$repo_root/scripts" \
      -type f \( -name '*.swift' -o -name '*.sh' \) -print
    printf '%s\n' "$repo_root/project.yml"
  } | LC_ALL=C sort | while IFS= read -r source_path; do
    shasum -a 256 "$source_path"
  done | shasum -a 256 | awk '{print $1}'
)
corpus_sha256=$(shasum -a 256 "$result_root/active/corpus.json" | awk '{print $1}')

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
  --arg power_mode "$(pmset -g custom | tr '\n' ' ')" \
  --arg thermal_state "$(pmset -g therm 2>&1 | tr '\n' ' ')" \
  '{git_revision:$git_revision,source_manifest_sha256:$source_manifest_sha256,corpus_sha256:$corpus_sha256,mac_model:$mac_model,ram_bytes:$ram_bytes,os_version:$os_version,os_build:$os_build,architecture:$architecture,xcode_version:$xcode_version,power_mode:$power_mode,thermal_state:$thermal_state,configuration:"Release"}' \
  >"$result_root/environment.json"

"$repo_root/scripts/check-s1-capture-spike.sh" "$result_root"
printf '%s\n' "$result_root"
