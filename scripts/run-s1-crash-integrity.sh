#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
required_count=${1:-30}
result_root=${2:?usage: run-s1-crash-integrity.sh [COUNT] RESULT_ROOT}
app_bundle="$repo_root/.build/LM005/Build/Products/Release/Local Memory.app"
json_lines="$result_root/crash-integrity.jsonl"
crash_runs_root="$result_root/crash-runs-$(date -u +%Y%m%dT%H%M%SZ)"

mkdir -p "$crash_runs_root"
: >"$json_lines"

for forced_second in $(seq 1 "$required_count"); do
  run_dir="$crash_runs_root/second-$(printf '%02d' "$forced_second")"
  mkdir -p "$run_dir"
  open -W -n "$app_bundle" --args \
    --capture-spike "$run_dir" \
    --capture-spike-duration 90 \
    --capture-spike-static \
    --capture-spike-crash-active \
    >"$run_dir/open.stdout.log" \
    2>"$run_dir/open.stderr.log" &
  launcher_pid=$!

  app_pid=""
  for _ in $(seq 1 100); do
    app_pid=$(ps ax -o pid=,command= | awk -v needle="$run_dir" '
      index($0, needle) > 0 && index($0, "Local Memory.app/Contents/MacOS/Local Memory") > 0 {pid=$1}
      END {if (pid) print pid}
    ')
    [[ -n "$app_pid" ]] && break
    sleep 0.1
  done
  if [[ -z "$app_pid" ]]; then
    wait "$launcher_pid" || true
    printf 'Unable to resolve app process for forced second %s\n' "$forced_second" >&2
    exit 1
  fi

  partial="$run_dir/.capture.mov.partial.mov"
  for _ in $(seq 1 300); do
    [[ -s "$partial" ]] && break
    sleep 0.1
  done
  if [[ ! -s "$partial" ]]; then
    kill -9 "$app_pid" 2>/dev/null || true
    wait "$launcher_pid" || true
    printf 'No durable first fragment for forced second %s\n' "$forced_second" >&2
    exit 1
  fi

  sleep "$((forced_second - 1))"
  kill -9 "$app_pid"
  wait "$launcher_pid" || true

  artifact="$partial"
  if [[ ! -s "$artifact" ]]; then
    artifact=$(find "$run_dir" -maxdepth 1 -type f -name 'capture*.mov' -size +0c -print | sort | tail -1)
  fi
  if [[ -z "$artifact" || ! -s "$artifact" ]]; then
    printf 'No durable media artifact after forced second %s\n' "$forced_second" >&2
    exit 1
  fi
  codec=$(ffprobe -v error -select_streams v:0 -show_entries stream=codec_name -of default=noprint_wrappers=1:nokey=1 "$artifact")
  duration=$(ffprobe -v error -show_entries format=duration -of default=noprint_wrappers=1:nokey=1 "$artifact")
  bytes=$(stat -f '%z' "$artifact")
  test "$codec" = hevc
  jq -cn \
    --argjson forced_second "$forced_second" \
    --arg path "$artifact" \
    --arg codec "$codec" \
    --argjson duration_seconds "$duration" \
    --argjson bytes "$bytes" \
    '{forced_second:$forced_second,path:$path,codec:$codec,duration_seconds:$duration_seconds,bytes:$bytes,playable:true}' \
    >>"$json_lines"
  printf 'S1 crash integrity %02d/%02d passed (%s bytes, %ss)\n' \
    "$forced_second" "$required_count" "$bytes" "$duration"
done

jq -s --argjson required_count "$required_count" \
  '{required_count:$required_count,results:.}' "$json_lines" \
  >"$result_root/crash-integrity.json"
rm "$json_lines"
