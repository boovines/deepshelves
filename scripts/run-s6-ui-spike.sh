#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_root="${1:-$repo_root/Benchmarks/Results/S6/$timestamp}"
build_root="$repo_root/.build/S6UIDerivedData"
transient_output="/Users/justinhou/Library/Containers/.xctrunner/Data/tmp/deepshelves-s6-xcuitest-current"
media_fixture="$repo_root/Benchmarks/Results/S1/20260827T173516Z/active/capture.mov"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-s6.XXXXXX")"
result_bundle="$temporary_root/S6.xcresult"
attachment_root="$temporary_root/attachments"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$repo_root"
if [[ -e "$output_root" ]]; then
    echo "Refusing to overwrite S6 output: $output_root" >&2
    exit 1
fi
[[ -f "$media_fixture" ]]
mkdir -p "$output_root"

"$repo_root/scripts/bootstrap-dependencies.sh" --offline "$repo_root/.dependency-cache" \
    > "$output_root/dependency-verification.log"
"$repo_root/scripts/materialize-dependencies.sh" "$repo_root/.dependency-cache" \
    >> "$output_root/dependency-verification.log"
xcodegen generate --spec project.yml > "$output_root/xcodegen.log"

set +e
set -o pipefail
xcodebuild \
    -project LocalMemory.xcodeproj \
    -scheme LocalMemory-UI \
    -configuration Release \
    -derivedDataPath "$build_root" \
    -destination 'platform=macOS,arch=arm64' \
    -resultBundlePath "$result_bundle" \
    -disableAutomaticPackageResolution \
    ONLY_ACTIVE_ARCH=YES \
    -only-testing:LocalMemoryUITests/S6PerformanceUITests \
    test 2>&1 | tee "$output_root/xcodebuild.log"
status=${PIPESTATUS[0]}
set -e

if [[ -d "$result_bundle" ]]; then
    xcrun xcresulttool get test-results summary --path "$result_bundle" \
        > "$output_root/xcresult-summary.json"
    mkdir -p "$attachment_root"
    xcrun xcresulttool export attachments --path "$result_bundle" \
        --output-path "$attachment_root" > "$output_root/xcresult-export.log"
    cp "$attachment_root/manifest.json" "$output_root/attachment-manifest.json"
    screenshot_name="$(jq -r '
      [.[].attachments[] |
        select(.suggestedHumanReadableName | startswith("S6 native grid timeline"))]
      | first | .exportedFileName // empty
    ' "$attachment_root/manifest.json")"
    if [[ -n "$screenshot_name" ]]; then
        cp "$attachment_root/$screenshot_name" "$output_root/s6-ui.png"
    fi
fi

for artifact in s6-report.json s6-xcuitest.json; do
    if [[ -f "$transient_output/$artifact" ]]; then
        cp "$transient_output/$artifact" "$output_root/$artifact"
    fi
done

app="$build_root/Build/Products/Release/Local Memory.app"
runner="$build_root/Build/Products/Release/LocalMemoryUITests-Runner.app"
{
    codesign -dv --verbose=4 "$app" 2>&1
    codesign -dv --verbose=4 "$runner" 2>&1
} > "$output_root/signatures.txt"
codesign --verify --deep --strict "$app"
codesign --verify --deep --strict "$runner"

git_revision="$(git rev-parse HEAD)"
source_manifest_sha256="$(find Apps Packages/MemoryDesignSystem Tests/UI scripts -type f \
    \( -name '*.swift' -o -name '*.sh' -o -name 'Package.swift' \) -print0 |
    sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"
jq -n \
  --arg gitRevision "$git_revision" \
  --arg sourceManifestSHA256 "$source_manifest_sha256" \
  --arg mediaFixtureSHA256 "$(shasum -a 256 "$media_fixture" | awk '{print $1}')" \
  --arg macModel "$(sysctl -n hw.model)" \
  --argjson ramBytes "$(sysctl -n hw.memsize)" \
  --arg osVersion "$(sw_vers -productVersion)" \
  --arg osBuild "$(sw_vers -buildVersion)" \
  --arg architecture "$(uname -m)" \
  --arg xcodeVersion "$(xcodebuild -version | tr '\n' ' ')" \
  '{schemaVersion:1,gitRevision:$gitRevision,sourceManifestSHA256:$sourceManifestSHA256,mediaFixtureSHA256:$mediaFixtureSHA256,macModel:$macModel,ramBytes:$ramBytes,osVersion:$osVersion,osBuild:$osBuild,architecture:$architecture,xcodeVersion:$xcodeVersion,configuration:"Release",onlyActiveArchitecture:true,uiFramework:"SwiftUI composition with NSCollectionView hot collection",signedApplication:true,signedXCUITestRunner:true}' \
  > "$output_root/environment.json"

if [[ "$status" -ne 0 ]]; then
    echo "S6 Release XCUITest failed with status $status; evidence preserved at $output_root" >&2
    exit "$status"
fi

"$repo_root/scripts/check-s6-ui-spike.sh" "$output_root"
echo "$output_root"
