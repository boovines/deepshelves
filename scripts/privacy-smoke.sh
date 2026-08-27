#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

source_roots=(Apps Packages)
forbidden='(^|[^A-Za-z])(URLSession|NWConnection|NWListener|CFSocket|CFHost|TelemetryDeck|SentrySDK|Sparkle|SUUpdater|socket\s*\()'
if rg -n --glob '*.swift' "$forbidden" "${source_roots[@]}"; then
    echo "Runtime networking or telemetry symbol found in shipping source." >&2
    exit 1
fi

if rg -n --glob '*.swift' 'https?://' "${source_roots[@]}"; then
    echo "Remote URL literal found in shipping source." >&2
    exit 1
fi

if rg -n 'url:\s*https?://' project.yml Packages/*/Package.swift; then
    echo "Remote package dependency found in bootstrap graph." >&2
    exit 1
fi

if rg -n 'com\.apple\.security\.network\.(client|server)' Apps project.yml; then
    echo "Network entitlement found." >&2
    exit 1
fi

echo "privacy-smoke: zero runtime networking, telemetry, remote packages, or network entitlements"

