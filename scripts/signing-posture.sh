#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

if ! security find-identity -v -p codesigning | rg -q 'Apple Development:'; then
    echo "No valid Apple Development signing identity is available." >&2
    exit 1
fi

xcodegen generate --spec project.yml
schemes=(LocalMemoryApp LocalMemoryCLI LocalMemoryMCP)
for scheme in "${schemes[@]}"; do
    echo "Signing $scheme sequentially"
    xcodebuild \
        -project LocalMemory.xcodeproj \
        -scheme "$scheme" \
        -configuration Release \
        -derivedDataPath .build/SignedDerivedData \
        -disableAutomaticPackageResolution \
        -allowProvisioningUpdates \
        build
done

products=(
    ".build/SignedDerivedData/Build/Products/Release/Local Memory.app"
    ".build/SignedDerivedData/Build/Products/Release/local-memory"
    ".build/SignedDerivedData/Build/Products/Release/local-memory-mcp"
)

for product in "${products[@]}"; do
    codesign --verify --deep --strict "$product"
    flags="$(codesign -dvv "$product" 2>&1)"
    if ! rg -q 'flags=.*runtime' <<<"$flags"; then
        echo "Hardened Runtime is absent from $product" >&2
        exit 1
    fi
    entitlements="$(codesign -d --entitlements :- "$product" 2>/dev/null)"
    if rg -q 'com\.apple\.security\.app-sandbox|com\.apple\.security\.network\.(client|server)' <<<"$entitlements"; then
        echo "Forbidden sandbox or network entitlement found in $product" >&2
        exit 1
    fi
    if ! rg -q 'com\.justinhou\.deepshelves\.shared' <<<"$entitlements"; then
        echo "Shared Keychain group is absent from $product" >&2
        exit 1
    fi
done

echo "signing-posture: signed products use Hardened Runtime, shared Keychain scope, and no sandbox/network entitlements"
