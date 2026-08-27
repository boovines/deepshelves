#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="${1:-$repo_root/.dependency-cache}"
manifest="$repo_root/Dependencies/dependencies.json"
materialized_root="$repo_root/.build/Dependencies"
grdb_revision="a285e4ca87ec6b3584c97b0ec25fc61fec02de60"
grdb_root="$materialized_root/GRDB.swift-$grdb_revision"
sqlcipher_root="$materialized_root/SQLCipher.swift"

verify_component_artifact() {
    local component="$1"
    local cache_path="$2"
    local expected_size
    local expected_hash
    local artifact
    artifact="$cache_root/$cache_path"
    expected_size="$(jq -r --arg component "$component" --arg path "$cache_path" \
        '.components[] | select(.id == $component) | .artifacts[] |
         select(.cachePath == $path) | .expectedSize' "$manifest")"
    expected_hash="$(jq -r --arg component "$component" --arg path "$cache_path" \
        '.components[] | select(.id == $component) | .artifacts[] |
         select(.cachePath == $path) | .sha256' "$manifest")"
    [[ -f "$artifact" ]]
    [[ "$(stat -f '%z' "$artifact")" == "$expected_size" ]]
    [[ "$(shasum -a 256 "$artifact" | awk '{print $1}')" == "$expected_hash" ]]
}

mkdir -p "$materialized_root"

verify_component_artifact \
    "grdb-sqlcipher" \
    "sources/grdb-sqlcipher-7.11.1.tar.gz"
verify_component_artifact \
    "sqlcipher-swift" \
    "binaries/SQLCipher.xcframework-4.18.0.zip"

if [[ ! -f "$grdb_root/.deepshelves-materialized" ]]; then
    tar -xzf "$cache_root/sources/grdb-sqlcipher-7.11.1.tar.gz" \
        -C "$materialized_root"
    cp "$repo_root/Dependencies/PackageTemplates/GRDB.Package.swift" \
        "$grdb_root/Package.swift"
    printf '%s\n' "$grdb_revision" > "$grdb_root/.deepshelves-materialized"
fi

if [[ ! -f "$sqlcipher_root/.deepshelves-materialized" ]]; then
    staging="$materialized_root/SQLCipher.swift.staging"
    mkdir -p "$staging"
    unzip -q "$cache_root/binaries/SQLCipher.xcframework-4.18.0.zip" \
        -d "$staging"
    cp "$repo_root/Dependencies/PackageTemplates/SQLCipher.Package.swift" \
        "$staging/Package.swift"
    printf '%s\n' "4.18.0" > "$staging/.deepshelves-materialized"
    mv "$staging" "$sqlcipher_root"
fi

echo "materialized-dependencies: GRDB 7.11.1 + SQLCipher 4.18.0 from verified offline cache"
