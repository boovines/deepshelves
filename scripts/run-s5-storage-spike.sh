#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_root="${1:-$repo_root/Benchmarks/Results/S5/$timestamp}"
build_root="$repo_root/.build/S5SignedDerivedData"
tools_root="$repo_root/.build/Tools"
unsigned_probe="$tools_root/lm008-unsigned-keychain-probe"
media_fixture="$repo_root/Benchmarks/Results/S1/20260827T173516Z/active/capture.mov"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-s5.XXXXXX")"
stdout_log="$temporary_root/stdout.log"
stderr_log="$temporary_root/stderr.log"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$repo_root"
if [[ -e "$output_root" ]]; then
    echo "Refusing to overwrite S5 output: $output_root" >&2
    exit 1
fi

"$repo_root/scripts/bootstrap-dependencies.sh" --offline "$repo_root/.dependency-cache" \
    > "$temporary_root/dependency-verification.log"
"$repo_root/scripts/materialize-dependencies.sh" "$repo_root/.dependency-cache" \
    >> "$temporary_root/dependency-verification.log"
xcodegen generate --spec project.yml >/dev/null

xcodebuild \
    -project LocalMemory.xcodeproj \
    -scheme LocalMemoryApp \
    -configuration Release \
    -derivedDataPath "$build_root" \
    -disableAutomaticPackageResolution \
    -allowProvisioningUpdates \
    build > "$temporary_root/build.log"

app="$build_root/Build/Products/Release/Local Memory.app"
binary="$app/Contents/MacOS/Local Memory"
codesign --verify --deep --strict "$app"
codesign -d --entitlements :- "$app" > "$temporary_root/signed-entitlements.plist" 2>/dev/null

mkdir -p "$tools_root"
xcrun swiftc \
    "$repo_root/Benchmarks/Tools/UnsignedKeychainProbe.swift" \
    -framework Security \
    -o "$unsigned_probe"

set +e
TMPDIR="$temporary_root" "$binary" \
    --lm008-s5-spike "$output_root" "$unsigned_probe" "$media_fixture" \
    > "$stdout_log" 2> "$stderr_log"
status=$?
set -e

if [[ ! -d "$output_root" ]]; then
    echo "S5 app did not create its output directory" >&2
    exit 1
fi
cp "$stdout_log" "$output_root/app.stdout.log"
cp "$stderr_log" "$output_root/app.stderr.log"
cp "$temporary_root/build.log" "$output_root/build.log"
cp "$temporary_root/dependency-verification.log" "$output_root/dependency-verification.log"
cp "$temporary_root/signed-entitlements.plist" "$output_root/signed-entitlements.plist"
if [[ "$status" -ne 0 ]]; then
    echo "S5 signed app failed with status $status; evidence preserved at $output_root" >&2
    exit "$status"
fi

git_revision="$(git rev-parse HEAD)"
source_manifest_sha256="$(find Packages Apps Benchmarks/Tools scripts -type f \
    \( -name '*.swift' -o -name '*.sh' -o -name 'Package.swift' \) -print0 |
    sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
corpus_sha256="$(jq -S '.encryption.sentinelCount,.faultInjection.crashPointCount,.processCrashes.boundaries' \
    "$output_root/s5-report.json" | shasum -a 256 | awk '{print $1}')"
jq -n \
  --arg git_revision "$git_revision" \
  --arg source_manifest_sha256 "$source_manifest_sha256" \
  --arg corpus_sha256 "$corpus_sha256" \
  --arg mac_model "$(sysctl -n hw.model)" \
  --argjson ram_bytes "$(sysctl -n hw.memsize)" \
  --arg os_version "$(sw_vers -productVersion)" \
  --arg os_build "$(sw_vers -buildVersion)" \
  --arg architecture "$(uname -m)" \
  --arg xcode_version "$(xcodebuild -version | tr '\n' ' ')" \
  '{git_revision:$git_revision,source_manifest_sha256:$source_manifest_sha256,corpus_sha256:$corpus_sha256,mac_model:$mac_model,ram_bytes:$ram_bytes,os_version:$os_version,os_build:$os_build,architecture:$architecture,xcode_version:$xcode_version,configuration:"Release",keychainScope:"shared signed app executable modes; unsigned and mismatched probes denied"}' \
  > "$output_root/environment.json"

"$repo_root/scripts/check-s5-storage-spike.sh" "$output_root"
echo "$output_root"
