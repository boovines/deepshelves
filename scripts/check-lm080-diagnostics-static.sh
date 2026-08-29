#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

core="Packages/MemoryStore/Sources/MemoryStore/LocalDiagnostics.swift"
app="Apps/LocalMemoryApp/DiagnosticsPresentation.swift"
composition=(
  "Apps/LocalMemoryApp/AppComposition.swift"
  "Apps/LocalMemoryApp/SearchPresentation.swift"
)

if rg -n 'URLSession|NW(Connection|Listener)|socket\s*\(|TelemetryDeck|Sentry|import (AVFoundation|VideoToolbox|ScreenCaptureKit|ImageIO)' \
  "$core" "$app" "${composition[@]}"; then
  echo "Diagnostics introduced a network, telemetry, capture, or media runtime boundary." >&2
  exit 1
fi

record_source="$(sed -n '/public struct LocalDiagnosticRecord/,/public enum ContentFreeDiagnosticCodec/p' "$core")"
if printf '%s\n' "$record_source" | rg -ni '\b(query|title|url|text|pixel|audio|transcript|content|bundleID|applicationName)\b'; then
  echo "Content-bearing field found in the durable diagnostic record." >&2
  exit 1
fi

rg -q 'maximumFileBytes: Int = 1_048_576' "$core"
rg -q 'maximumFiles: Int = 3' "$core"
rg -q 'line.count <= 8_192' "$core"
rg -q 'includesCapturedContent: false' "$core"
rg -q 'isSymbolicLink != true' "$core"
rg -q 'ContentFreeDiagnosticCodec.decoder.decode' "$core"

if rg -n 'Timer\.|scheduledTimer|asyncAfter|while true|Task\.sleep' "$app"; then
  echo "Diagnostics UI must refresh only on open or explicit user action." >&2
  exit 1
fi

echo "lm080-diagnostics-static: typed content-free records, bounded owner-only logs, revalidated local export, and nonpolling UI verified"
