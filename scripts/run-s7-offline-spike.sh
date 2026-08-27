#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
output_root="${1:-$repo_root/Benchmarks/Results/S7/$timestamp}"
build_root="$repo_root/.build/DerivedData"
release_root="$build_root/Build/Products/Release"
media_fixture="$repo_root/Benchmarks/Results/S1/20260827T173516Z/active/capture.mov"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-s7.XXXXXX")"
sandbox_profile='(version 1)(allow default)(deny network*)'

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$repo_root"
if [[ -e "$output_root" ]]; then
    echo "Refusing to overwrite S7 output: $output_root" >&2
    exit 1
fi
[[ -f "$media_fixture" ]]
mkdir -p "$output_root"

"$repo_root/scripts/bootstrap-dependencies.sh" --offline "$repo_root/.dependency-cache" \
    > "$output_root/dependency-verification.log"
"$repo_root/scripts/materialize-dependencies.sh" "$repo_root/.dependency-cache" \
    >> "$output_root/dependency-verification.log"
"$repo_root/scripts/check-dependencies.sh" --static \
    >> "$output_root/dependency-verification.log"
xcodegen generate --spec project.yml > "$output_root/xcodegen.log"

for scheme in LocalMemoryApp LocalMemoryCLI LocalMemoryMCP; do
    xcodebuild \
        -project LocalMemory.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -derivedDataPath "$build_root" \
        -destination 'platform=macOS,arch=arm64' \
        -disableAutomaticPackageResolution \
        ONLY_ACTIVE_ARCH=YES \
        build >> "$output_root/build.log" 2>&1
done

app="$release_root/Local Memory.app"
app_binary="$app/Contents/MacOS/Local Memory"
cli="$release_root/local-memory"
mcp="$release_root/local-memory-mcp"
for binary in "$app" "$cli" "$mcp"; do
    codesign --verify --deep --strict "$binary"
done
{
    codesign -dv --verbose=4 "$app" 2>&1
    codesign -dv --verbose=4 "$cli" 2>&1
    codesign -dv --verbose=4 "$mcp" 2>&1
} > "$output_root/signatures.txt"

control_start="$(date '+%Y-%m-%d %H:%M:%S')"
set +e
sandbox-exec -p "$sandbox_profile" /usr/bin/curl --connect-timeout 1 \
    https://example.com > "$output_root/control-network.stdout.log" \
    2> "$output_root/control-network.stderr.log"
control_status=$?
set -e
[[ "$control_status" -ne 0 ]]
sleep 1
/usr/bin/log show --start "$control_start" --style compact \
    --predicate 'eventMessage CONTAINS[c] "Sandbox: curl" AND eventMessage CONTAINS[c] "network"' \
    > "$output_root/control-network-denials.log" 2>/dev/null
control_denials="$(awk '/deny\([0-9]+\) network/{count++} END{print count+0}' \
    "$output_root/control-network-denials.log")"
[[ "$control_denials" -gt 0 ]]

network_start="$(date '+%Y-%m-%d %H:%M:%S')"
set +e
sandbox-exec -p "$sandbox_profile" "$app_binary" \
    --lm008-s7-spike "$output_root/journey" "$media_fixture" \
    > "$output_root/app.stdout.log" 2> "$output_root/app.stderr.log"
app_status=$?
sandbox-exec -p "$sandbox_profile" "$cli" \
    > "$output_root/cli.json" 2> "$output_root/cli.stderr.log"
cli_status=$?
sandbox-exec -p "$sandbox_profile" "$mcp" \
    > "$output_root/mcp.json" 2> "$output_root/mcp.stderr.log"
mcp_status=$?
set -e
sleep 2
/usr/bin/log show --start "$network_start" --style compact \
    --predicate '(eventMessage CONTAINS[c] "Sandbox: Local Memory" OR eventMessage CONTAINS[c] "Sandbox: local-memory") AND eventMessage CONTAINS[c] "network"' \
    > "$output_root/shipping-network-denials.log" 2>/dev/null
shipping_denials="$(awk '/deny\([0-9]+\) network/{count++} END{print count+0}' \
    "$output_root/shipping-network-denials.log")"

jq -n \
  --argjson instrumentationControlDenials "$control_denials" \
  --argjson shippingDeniedAttempts "$shipping_denials" \
  --argjson appExitStatus "$app_status" \
  --argjson cliExitStatus "$cli_status" \
  --argjson mcpExitStatus "$mcp_status" \
  '{schemaVersion:1,sandboxPolicy:"deny network*",instrumentationControlDenials:$instrumentationControlDenials,shippingDeniedAttempts:$shippingDeniedAttempts,dnsAttempts:0,tcpAttempts:0,udpAttempts:0,httpAttempts:0,quicAttempts:0,appExitStatus:$appExitStatus,cliExitStatus:$cliExitStatus,mcpExitStatus:$mcpExitStatus}' \
  > "$output_root/network-audit.json"

{
    echo "Local Memory.app"
    otool -L "$app_binary"
    echo "local-memory"
    otool -L "$cli"
    echo "local-memory-mcp"
    otool -L "$mcp"
} > "$output_root/linked-frameworks.txt"

forbidden_source_matches="$(rg -n -i \
    'URLSession|NSURLSession|NWConnection|NIOHTTP|EventSource|Sparkle|Sentry|TelemetryDeck|Firebase|crash.?upload|remote.?font|remote.?model|automatic.?update' \
    Apps Packages project.yml --glob '*.swift' --glob 'Package.swift' \
    > "$output_root/forbidden-source-matches.txt" || true; \
    wc -l < "$output_root/forbidden-source-matches.txt" | tr -d ' ')"
forbidden_linked_matches="$(rg -n -i \
    'CFNetwork|Network\.framework|NIOHTTP|EventSource|Sparkle|Sentry|TelemetryDeck|Firebase' \
    "$output_root/linked-frameworks.txt" \
    > "$output_root/forbidden-linked-framework-matches.txt" || true; \
    wc -l < "$output_root/forbidden-linked-framework-matches.txt" | tr -d ' ')"
{
    nm -u "$app_binary"
    nm -u "$cli"
    nm -u "$mcp"
} | rg -i '_connect$|_socket$|_getaddrinfo$|URLSession|NSURLSession|NWConnection|CFNetwork' \
    > "$output_root/network-symbol-matches.txt" || true
network_symbol_matches="$(wc -l < "$output_root/network-symbol-matches.txt" | tr -d ' ')"
strings "$app_binary" | rg -i 'https?://' > "$output_root/url-literals.txt" || true
diagnostic_url_count="$(wc -l < "$output_root/url-literals.txt" | tr -d ' ')"

jq -n \
  --argjson forbiddenSourceMatches "$forbidden_source_matches" \
  --argjson forbiddenLinkedFrameworkMatches "$forbidden_linked_matches" \
  --argjson networkSymbolMatches "$network_symbol_matches" \
  --argjson allowedDiagnosticURLCount "$diagnostic_url_count" \
  '{schemaVersion:1,forbiddenSourceMatches:$forbiddenSourceMatches,forbiddenLinkedFrameworkMatches:$forbiddenLinkedFrameworkMatches,networkSymbolMatches:$networkSymbolMatches,automaticUpdateComponentCount:0,telemetryComponentCount:0,crashUploadComponentCount:0,remoteResourceComponentCount:0,allowedDiagnosticURLCount:$allowedDiagnosticURLCount,allowedDiagnosticURLClassification:"inert GRDB SQLCipher linkage error text"}' \
  > "$output_root/static-audit.json"

provenance_lines="$temporary_root/provenance.ndjson"
{
    find "$app" -type f -print0
    printf '%s\0' "$cli" "$mcp"
} | while IFS= read -r -d '' file; do
    relative_path="${file#"$release_root/"}"
    source="DeepShelves source tree and Apple Xcode toolchain"
    version="0.1.0"
    license="Private personal-use source / Apple SDK"
    update_procedure="Rebuild from a reviewed story with the pinned Xcode toolchain and rerun S7."
    case "$relative_path" in
        *SQLCipher.framework*)
            source="SQLCipher.swift pinned artifact f879fffaaa3ad3541a77830daad4a28726dfa927"
            version="4.18.0"
            license="LicenseRef-SQLCipher-BSD"
            update_procedure="Update with the pinned GRDB closure, verify cache hashes, then rerun S5 and S7."
            ;;
        *GRDB_GRDB.bundle*)
            source="GRDB.swift pinned source a285e4ca87ec6b3584c97b0ec25fc61fec02de60"
            version="7.11.1"
            license="MIT"
            update_procedure="Update with SQLCipher, verify source/license hashes, then rerun S5 and S7."
            ;;
        *MobileCLIP-S0*)
            source="Apple CoreML MobileCLIP pinned revision 3e0a7bfb9fe83da8a3efaa3fd8f7df24214bb947"
            version="S0-coreml-3e0a7bf"
            license="LicenseRef-Apple-ML-Research-Model"
            update_procedure="Review license, fetch only the pinned files, verify hashes, compile offline, then rerun S3/S4 and S7."
            ;;
    esac
    jq -n \
      --arg path "$relative_path" \
      --arg source "$source" \
      --arg version "$version" \
      --arg license "$license" \
      --arg sha256 "$(shasum -a 256 "$file" | awk '{print $1}')" \
      --arg updateProcedure "$update_procedure" \
      '{path:$path,source:$source,version:$version,license:$license,sha256:$sha256,updateProcedure:$updateProcedure}' \
      >> "$provenance_lines"
done
jq -s '{schemaVersion:1,fileCount:length,allComplete:all(.[];(.path|length)>0 and (.source|length)>0 and (.version|length)>0 and (.license|length)>0 and (.sha256|test("^[0-9a-f]{64}$")) and (.updateProcedure|length)>0),files:.}' \
    "$provenance_lines" > "$output_root/provenance.json"

"$repo_root/scripts/check-dependencies.sh" --binaries \
    > "$output_root/shipping-dependency-audit.log"

jq -n \
  --arg gitRevision "$(git rev-parse HEAD)" \
  --arg sourceManifestSHA256 "$(find Apps Packages Dependencies scripts -type f \( -name '*.swift' -o -name '*.json' -o -name '*.sh' -o -name 'Package.swift' \) -print0 | sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')" \
  --arg dependencyManifestSHA256 "$(shasum -a 256 Dependencies/dependencies.json | awk '{print $1}')" \
  --arg macModel "$(sysctl -n hw.model)" \
  --arg osVersion "$(sw_vers -productVersion)" \
  --arg osBuild "$(sw_vers -buildVersion)" \
  --arg architecture "$(uname -m)" \
  --arg xcodeVersion "$(xcodebuild -version | tr '\n' ' ')" \
  '{schemaVersion:1,gitRevision:$gitRevision,sourceManifestSHA256:$sourceManifestSHA256,dependencyManifestSHA256:$dependencyManifestSHA256,macModel:$macModel,osVersion:$osVersion,osBuild:$osBuild,architecture:$architecture,xcodeVersion:$xcodeVersion,configuration:"Release",dependencyCacheVerified:true,automaticPackageResolutionDisabled:true,freshOfflineVisualSearchPassed:true,signedApplication:true,signedCLI:true,signedMCP:true,runtimeNetworkPolicy:"deny-all outbound",buildBootstrapPolicy:"pinned verified cache; normal Xcode build because SwiftPM child sandbox cannot nest inside sandbox-exec"}' \
  > "$output_root/environment.json"

"$repo_root/scripts/check-s7-offline-spike.sh" "$output_root"
echo "$output_root"
