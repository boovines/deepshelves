#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
manifest="$repo_root/Dependencies/dependencies.json"
mode="${1:-}"
cache_root="${2:-$repo_root/.dependency-cache}"

if [[ "$mode" != "--fetch" && "$mode" != "--offline" ]]; then
    echo "Usage: $0 --fetch|--offline [cache-directory]" >&2
    exit 64
fi

command -v jq >/dev/null
command -v shasum >/dev/null

verify_artifact() {
    local component="$1"
    local path="$2"
    local expected_size="$3"
    local expected_hash="$4"

    if [[ ! -f "$path" ]]; then
        echo "Missing cached artifact for $component: $path" >&2
        return 1
    fi

    local actual_size
    actual_size="$(stat -f '%z' "$path")"
    if [[ "$actual_size" != "$expected_size" ]]; then
        echo "Size mismatch for $component: $path ($actual_size != $expected_size)" >&2
        return 1
    fi

    local actual_hash
    actual_hash="$(shasum -a 256 "$path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "SHA-256 mismatch for $component: $path" >&2
        return 1
    fi
}

mkdir -p "$cache_root"
artifact_count=0

while IFS=$'\t' read -r component cache_path url expected_size expected_hash; do
    destination="$cache_root/$cache_path"
    artifact_count=$((artifact_count + 1))

    if [[ "$mode" == "--fetch" ]]; then
        mkdir -p "$(dirname "$destination")"
        if verify_artifact "$component" "$destination" "$expected_size" "$expected_hash" 2>/dev/null; then
            echo "verified existing: $cache_path"
            continue
        fi
        if [[ -e "$destination" ]]; then
            echo "Refusing to overwrite mismatched cache file: $destination" >&2
            exit 1
        fi

        partial="$destination.partial"
        echo "fetching: $component / $cache_path"
        curl --fail --location --retry 3 --continue-at - --output "$partial" "$url"
        verify_artifact "$component" "$partial" "$expected_size" "$expected_hash"
        mv "$partial" "$destination"
    fi

    verify_artifact "$component" "$destination" "$expected_size" "$expected_hash"
done < <(
    jq -r '.components[] as $component | $component.artifacts[] |
        select(.cachePath != null) |
        [$component.id, .cachePath, .url, (.expectedSize | tostring), .sha256] | @tsv' "$manifest"
)

echo "dependency-cache: $artifact_count artifacts verified in $mode mode at $cache_root"
