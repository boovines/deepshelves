#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cache_root="${1:-$repo_root/.dependency-cache}"
manifest="$repo_root/Dependencies/dependencies.json"
materialized_root="$repo_root/.build/Dependencies"
grdb_revision="a285e4ca87ec6b3584c97b0ec25fc61fec02de60"
grdb_root="$materialized_root/GRDB.swift-$grdb_revision"
sqlcipher_root="$materialized_root/SQLCipher.swift"
software_heic_archive="$cache_root/binaries/software-heic-libheif-1.23.2-x265-4.3-arm64-macos15.tar.gz"
software_heic_resources="$repo_root/Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/Resources/SoftwareHEIC"
software_heic_size="2273651"
software_heic_hash="ff359032e30591fce5614a60ca0f9be4e0f9e06acea7b64981051d0f867a5e50"

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
verify_component_artifact \
    "libheif-software-heic" \
    "sources/libheif-1.23.2.tar.gz"
verify_component_artifact \
    "x265-software-heic" \
    "sources/x265-4.3.tar.gz"
verify_component_artifact \
    "libde265-software-heic" \
    "sources/libde265-1.1.1.tar.gz"

if [[ ! -f "$software_heic_archive" ]] \
    || [[ "$(stat -f '%z' "$software_heic_archive" 2>/dev/null || true)" != "$software_heic_size" ]] \
    || [[ "$(shasum -a 256 "$software_heic_archive" 2>/dev/null | awk '{print $1}')" != "$software_heic_hash" ]]; then
    "$repo_root/scripts/build-software-heic-cache.sh"
fi
[[ "$(stat -f '%z' "$software_heic_archive")" == "$software_heic_size" ]]
[[ "$(shasum -a 256 "$software_heic_archive" | awk '{print $1}')" == "$software_heic_hash" ]]

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

mkdir -p "$software_heic_resources"
if find "$software_heic_resources" -mindepth 1 -type f \
    ! -name .gitkeep \
    ! -path '*/bin/lm-software-heic' \
    ! -path '*/lib/libheif.1.23.2.dylib' \
    ! -path '*/lib/libx265.217.dylib' \
    ! -path '*/lib/libde265.0.2.1.dylib' \
    ! -path '*/licenses/libheif-COPYING' \
    ! -path '*/licenses/x265-COPYING' \
    ! -path '*/licenses/libde265-COPYING' \
    ! -name SHA256SUMS | grep -q .; then
    echo "Unexpected file in the software HEIC resource inventory" >&2
    exit 1
fi
tar -xzf "$software_heic_archive" --strip-components=1 \
    -C "$software_heic_resources"
(
    cd "$software_heic_resources"
    shasum -a 256 -c SHA256SUMS >/dev/null
)
chmod 0755 "$software_heic_resources/bin/lm-software-heic"

echo "materialized-dependencies: GRDB + SQLCipher + software HEIC runtime from verified offline cache"
