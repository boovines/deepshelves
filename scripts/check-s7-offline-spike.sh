#!/bin/bash
set -euo pipefail

root="${1:?usage: check-s7-offline-spike.sh RESULTS_ROOT}"
journey="$root/journey/s7-journey.json"
network="$root/network-audit.json"
provenance="$root/provenance.json"
static_audit="$root/static-audit.json"
environment="$root/environment.json"

for artifact in "$journey" "$network" "$provenance" "$static_audit" "$environment" \
    "$root/build.log" "$root/signatures.txt" "$root/linked-frameworks.txt" \
    "$root/dependency-verification.log" "$root/control-network-denials.log" \
    "$root/shipping-network-denials.log" "$root/cli.json" "$root/mcp.json"; do
    [[ -f "$artifact" ]]
done

jq -e '
  .schemaVersion == 1 and
  .completedStages == ["firstLaunch","onboarding","capture","search","visualInference","deletion","export","cli","mcp"] and
  .freshArchiveOwnerOnly == true and
  .onboardingLocalOnly == true and
  .captureMediaBytes > 0 and
  .captureVideoTrackCount > 0 and
  .textSearchResultCount > 0 and
  .visualModelVersion == "mobileclip-s0-coreml-3e0a7bf" and
  .verifiedModelResourceCount == 12 and
  .visualEmbeddingDimension == 512 and
  .visualSearchResultCount > 0 and
  .visualTopResultIndex == 0 and
  .deletedArtifactAbsent == true and
  .exportManifestExists == true and
  .cliExitStatus == 0 and
  .cliTransport == "local-stdio" and
  .mcpExitStatus == 0 and
  .mcpTransport == "local-stdio" and
  .runtimeDownloadsAllowed == false and
  .remoteResourcesAllowed == false
' "$journey" >/dev/null

jq -e '
  .schemaVersion == 1 and
  .sandboxPolicy == "deny network*" and
  .instrumentationControlDenials > 0 and
  .shippingDeniedAttempts == 0 and
  .dnsAttempts == 0 and
  .tcpAttempts == 0 and
  .udpAttempts == 0 and
  .httpAttempts == 0 and
  .quicAttempts == 0 and
  .appExitStatus == 0 and
  .cliExitStatus == 0 and
  .mcpExitStatus == 0
' "$network" >/dev/null

jq -e '
  .schemaVersion == 1 and
  .fileCount > 10 and
  .allComplete == true and
  ([.files[].path] | length == (unique | length)) and
  all(.files[];
    (.path | length > 0) and
    (.source | length > 0) and
    (.version | length > 0) and
    (.license | length > 0) and
    (.sha256 | test("^[0-9a-f]{64}$")) and
    (.updateProcedure | length > 0))
' "$provenance" >/dev/null

jq -e '
  .schemaVersion == 1 and
  .forbiddenSourceMatches == 0 and
  .forbiddenLinkedFrameworkMatches == 0 and
  .networkSymbolMatches == 0 and
  .automaticUpdateComponentCount == 0 and
  .telemetryComponentCount == 0 and
  .crashUploadComponentCount == 0 and
  .remoteResourceComponentCount == 0 and
  .allowedDiagnosticURLCount == 1 and
  .allowedDiagnosticURLClassification == "inert GRDB SQLCipher linkage error text"
' "$static_audit" >/dev/null

jq -e '
  .configuration == "Release" and
  .dependencyCacheVerified == true and
  .automaticPackageResolutionDisabled == true and
  .freshOfflineVisualSearchPassed == true and
  .signedApplication == true and
  .signedCLI == true and
  .signedMCP == true and
  .runtimeNetworkPolicy == "deny-all outbound"
' "$environment" >/dev/null

jq -e '.component == "local-memory" and .state == "bootstrap"' "$root/cli.json" >/dev/null
jq -e '.component == "local-memory-mcp" and .state == "not-configured"' "$root/mcp.json" >/dev/null
rg -q 'deny\([0-9]+\) network' "$root/control-network-denials.log"
if rg -q 'deny\([0-9]+\) network' "$root/shipping-network-denials.log"; then
    echo "A shipping target attempted network access" >&2
    exit 1
fi
rg -q 'Authority=Apple Development:' "$root/signatures.txt"

echo "S7 cache-only build, complete offline journey, zero-network, and provenance gates passed: $root"
