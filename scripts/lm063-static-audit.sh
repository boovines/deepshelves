#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$repo_root/Results/LM-063/offline-static.json}"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-lm063-static.XXXXXX")"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

cd "$repo_root"
mkdir -p "$(dirname "$output")"

"$repo_root/scripts/bootstrap-dependencies.sh" --offline "$repo_root/.dependency-cache" \
    > "$temporary_root/cache.txt"
"$repo_root/scripts/check-dependencies.sh" --static \
    > "$temporary_root/dependencies.txt"

for script in \
    scripts/check-lm063-offline-gate.sh \
    scripts/run-lm063-offline-gate.sh \
    scripts/lm063-static-audit.sh; do
    bash -n "$script"
done

forbidden_source_matches="$({
    rg -n -i \
      'URLSession|NSURLSession|NWConnection|NIOHTTP|EventSource|Sparkle|Sentry|TelemetryDeck|Firebase|crash.?upload|remote.?font|remote.?model|automatic.?update' \
      Apps Packages project.yml --glob '*.swift' --glob 'Package.swift' || true
} | wc -l | tr -d ' ')"

model_manifest="Packages/MemoryEnrichment/Sources/MemoryEnrichment/Resources/MobileCLIP-S0/model-manifest.json"
model_root="$(dirname "$model_manifest")"
model_count="$(jq '.artifacts | length' "$model_manifest")"
model_verified=true
while IFS=$'\t' read -r relative expected_hash; do
    file="$model_root/$relative"
    if [[ ! -f "$file" ]] || \
       [[ "$(shasum -a 256 "$file" | awk '{print $1}')" != "$expected_hash" ]]; then
        model_verified=false
        break
    fi
done < <(jq -r '.artifacts[] | [.relativePath, .sha256] | @tsv' "$model_manifest")

dependency_manifest_hash="$(shasum -a 256 Dependencies/dependencies.json | awk '{print $1}')"
model_manifest_hash="$(shasum -a 256 "$model_manifest" | awk '{print $1}')"
source_manifest_hash="$(find Apps Packages scripts -type f \
    \( -name '*.swift' -o -name '*.sh' -o -name 'Package.swift' \) -print0 | \
    sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{print $1}')"

jq -n \
  --arg story "LM-063" \
  --arg proofClass "static-cache-manifest" \
  --argjson forbiddenSourceMatches "$forbidden_source_matches" \
  --argjson dependencyCacheVerified true \
  --argjson automaticPackageResolutionDisabled true \
  --argjson runtimeExecuted false \
  --argjson modelResourceCount "$model_count" \
  --argjson modelResourcesVerified "$model_verified" \
  --arg dependencyManifestSHA256 "$dependency_manifest_hash" \
  --arg modelManifestSHA256 "$model_manifest_hash" \
  --arg sourceManifestSHA256 "$source_manifest_hash" \
  '{schemaVersion:1,story:$story,status:"passed-static-only",proofClass:$proofClass,
    runtimeSubstitute:false,forbiddenSourceMatches:$forbiddenSourceMatches,
    dependencyCacheVerified:$dependencyCacheVerified,
    automaticPackageResolutionDisabled:$automaticPackageResolutionDisabled,
    runtimeExecuted:$runtimeExecuted,modelResourceCount:$modelResourceCount,
    modelResourcesVerified:$modelResourcesVerified,
    dependencyManifestSHA256:$dependencyManifestSHA256,
    modelManifestSHA256:$modelManifestSHA256,
    sourceManifestSHA256:$sourceManifestSHA256}' > "$output"

jq -e '
  .schemaVersion == 1 and .story == "LM-063" and
  .status == "passed-static-only" and .runtimeSubstitute == false and
  .forbiddenSourceMatches == 0 and .dependencyCacheVerified == true and
  .automaticPackageResolutionDisabled == true and .runtimeExecuted == false and
  .modelResourceCount > 0 and .modelResourcesVerified == true and
  (.dependencyManifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.modelManifestSHA256 | test("^[0-9a-f]{64}$")) and
  (.sourceManifestSHA256 | test("^[0-9a-f]{64}$"))
' "$output" >/dev/null

echo "$output"
