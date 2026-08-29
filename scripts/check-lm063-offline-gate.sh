#!/bin/bash
set -euo pipefail

report="${1:?usage: check-lm063-offline-gate.sh OFFLINE_JSON}"
[[ -f "$report" ]]

jq -e '
  .schemaVersion == 1 and
  .story == "LM-063" and
  .status == "passed" and
  .runtimeHost.isolatedValidationMac == true and
  .runtimeHost.sameAsOwnerLaptop == false and
  (.runtimeHost.hardwareUUIDSHA256 | test("^[0-9a-f]{64}$")) and
  .network.policy == "deny-all outbound" and
  .network.instrumentationControlDeniedAttempts > 0 and
  .network.shippingDeniedAttempts == 0 and
  .network.dnsAttempts == 0 and
  .network.tcpAttempts == 0 and
  .network.udpAttempts == 0 and
  .network.httpAttempts == 0 and
  .network.quicAttempts == 0 and
  .network.socketSymbolMatches == 0 and
  .network.dnsSymbolMatches == 0 and
  .journeys.completed == [
    "firstLaunch", "onboarding", "capture", "search", "visualInference",
    "deletion", "export", "cli", "mcp"
  ] and
  .journeys.allPassed == true and
  .build.dependencyCacheVerified == true and
  .build.automaticPackageResolutionDisabled == true and
  .build.runtimeDownloadsAllowed == false and
  .build.buildBootstrapOnly == true and
  .audit.forbiddenSourceMatches == 0 and
  .audit.forbiddenLinkedFrameworkMatches == 0 and
  .audit.telemetryComponents == 0 and
  .audit.crashUploadComponents == 0 and
  .audit.automaticUpdateComponents == 0 and
  .audit.remoteResourceComponents == 0 and
  .audit.provenanceComplete == true and
  .audit.modelResourcesVerified == true and
  .runtime.applicationExecuted == true and
  .runtime.cliExecuted == true and
  .runtime.mcpExecuted == true
' "$report" >/dev/null

echo "LM-063 isolated deny-all runtime and offline closure gate passed"
