#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
result_root=${1:-"$repo_root/Benchmarks/Results/S2/$timestamp"}
derived_data="$repo_root/.build/LM006"
app_bundle="$derived_data/Build/Products/Release/Local Memory.app"
app_binary="$app_bundle/Contents/MacOS/Local Memory"

mkdir -p "$result_root"
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

"$app_binary" --context-spike "$result_root" \
  >"$result_root/app.stdout.log" \
  2>"$result_root/app.stderr.log" &
launcher_pid=$!

for _ in $(seq 1 900); do
  if [[ -e "$result_root/context-spike-complete.marker" ]]; then
    break
  fi
  if ! kill -0 "$launcher_pid" 2>/dev/null; then
    break
  fi
  sleep 0.2
done
wait "$launcher_pid"
test -e "$result_root/context-spike-complete.marker"

source_manifest_sha256=$(
  {
    find "$repo_root/Apps" "$repo_root/Packages" "$repo_root/Tests" "$repo_root/Scripts" \
      -type f \( -name '*.swift' -o -name '*.sh' \) -print
    printf '%s\n' "$repo_root/project.yml"
  } | LC_ALL=C sort | while IFS= read -r source_path; do
    shasum -a 256 "$source_path"
  done | shasum -a 256 | awk '{print $1}'
)
corpus_sha256=$(
  {
    shasum -a 256 "$result_root/raw/fixture-catalog.json"
    find "$result_root/raw/ocr" -type f -name '*.png' -print0 \
      | LC_ALL=C sort -z \
      | xargs -0 shasum -a 256
  } | shasum -a 256 | awk '{print $1}'
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
  '{git_revision:$git_revision,source_manifest_sha256:$source_manifest_sha256,corpus_sha256:$corpus_sha256,mac_model:$mac_model,ram_bytes:$ram_bytes,os_version:$os_version,os_build:$os_build,architecture:$architecture,xcode_version:$xcode_version,configuration:"Release",liveProbeScope:"DeepShelves synthetic window only"}' \
  >"$result_root/environment.json"

"$repo_root/Scripts/check-s2-context-spike.sh" "$result_root"
printf '%s\n' "$result_root"
