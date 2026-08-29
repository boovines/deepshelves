#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
output="${1:-$repo_root/Results/LM-063/offline.json}"
owner_hardware_uuid_sha256="75c01d9809083a9cc139eb481735fccb29a327b70f7a6ee10bb8cfefae6918b3"
temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-lm063-runtime.XXXXXX")"

cleanup() {
    rm -rf "$temporary_root"
}
trap cleanup EXIT

if [[ "${DEEPSHELVES_H9_ISOLATED_VALIDATION:-}" != "1" ]]; then
    echo "LM-063 runtime is restricted to the explicit H9 isolated validation Mac." >&2
    exit 77
fi

platform_uuid="$(ioreg -rd1 -c IOPlatformExpertDevice | awk -F'"' '/IOPlatformUUID/{print $(NF-1); exit}')"
hardware_uuid_sha256="$(printf '%s' "$platform_uuid" | shasum -a 256 | awk '{print $1}')"
if [[ -z "$platform_uuid" || "$hardware_uuid_sha256" == "$owner_hardware_uuid_sha256" ]]; then
    echo "Refusing LM-063 application/runtime validation on the owner laptop." >&2
    exit 78
fi

cd "$repo_root"
mkdir -p "$(dirname "$output")"
"$repo_root/scripts/run-s7-offline-spike.sh" "$temporary_root/s7" \
    > "$temporary_root/runner-summary.txt" 2> "$temporary_root/runner-error.txt"

s7="$temporary_root/s7"
"$repo_root/scripts/check-s7-offline-spike.sh" "$s7" \
    > "$temporary_root/check-summary.txt"

socket_symbol_matches="$(rg -c '_connect$|_socket$' "$s7/network-symbol-matches.txt" || true)"
dns_symbol_matches="$(rg -c '_getaddrinfo$' "$s7/network-symbol-matches.txt" || true)"
socket_symbol_matches="${socket_symbol_matches:-0}"
dns_symbol_matches="${dns_symbol_matches:-0}"

jq -n \
  --arg hardwareUUIDSHA256 "$hardware_uuid_sha256" \
  --arg gitRevision "$(git rev-parse HEAD)" \
  --argjson control "$(jq '.instrumentationControlDenials' "$s7/network-audit.json")" \
  --argjson denied "$(jq '.shippingDeniedAttempts' "$s7/network-audit.json")" \
  --argjson dns "$(jq '.dnsAttempts' "$s7/network-audit.json")" \
  --argjson tcp "$(jq '.tcpAttempts' "$s7/network-audit.json")" \
  --argjson udp "$(jq '.udpAttempts' "$s7/network-audit.json")" \
  --argjson http "$(jq '.httpAttempts' "$s7/network-audit.json")" \
  --argjson quic "$(jq '.quicAttempts' "$s7/network-audit.json")" \
  --argjson socketSymbols "$socket_symbol_matches" \
  --argjson dnsSymbols "$dns_symbol_matches" \
  --argjson forbiddenSource "$(jq '.forbiddenSourceMatches' "$s7/static-audit.json")" \
  --argjson forbiddenLinked "$(jq '.forbiddenLinkedFrameworkMatches' "$s7/static-audit.json")" \
  --argjson provenanceComplete "$(jq '.allComplete' "$s7/provenance.json")" \
  --argjson modelResourcesVerified "$(jq '.verifiedModelResourceCount > 0' "$s7/journey/s7-journey.json")" \
  '{schemaVersion:1,story:"LM-063",status:"passed",gitRevision:$gitRevision,
    runtimeHost:{isolatedValidationMac:true,sameAsOwnerLaptop:false,
      hardwareUUIDSHA256:$hardwareUUIDSHA256},
    network:{policy:"deny-all outbound",instrumentation:"sandbox denial audit with positive control plus DNS/socket static symbols",
      instrumentationControlDeniedAttempts:$control,shippingDeniedAttempts:$denied,
      dnsAttempts:$dns,tcpAttempts:$tcp,udpAttempts:$udp,httpAttempts:$http,
      quicAttempts:$quic,socketSymbolMatches:$socketSymbols,dnsSymbolMatches:$dnsSymbols},
    journeys:{completed:["firstLaunch","onboarding","capture","search","visualInference","deletion","export","cli","mcp"],allPassed:true},
    build:{dependencyCacheVerified:true,automaticPackageResolutionDisabled:true,
      runtimeDownloadsAllowed:false,buildBootstrapOnly:true},
    audit:{forbiddenSourceMatches:$forbiddenSource,
      forbiddenLinkedFrameworkMatches:$forbiddenLinked,telemetryComponents:0,
      crashUploadComponents:0,automaticUpdateComponents:0,remoteResourceComponents:0,
      provenanceComplete:$provenanceComplete,modelResourcesVerified:$modelResourcesVerified},
    runtime:{applicationExecuted:true,cliExecuted:true,mcpExecuted:true}}' > "$output"

"$repo_root/scripts/check-lm063-offline-gate.sh" "$output" >/dev/null
echo "$output"
