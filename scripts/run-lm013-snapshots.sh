#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
package_root="$repo_root/Packages/MemoryDesignSystem"
mode="${1:---check}"

run_renderer() {
    local output_root="$1"
    swift run \
        --quiet \
        --package-path "$package_root" \
        --scratch-path "$repo_root/.build/MemoryDesignSystemSnapshot" \
        -c release \
        MemorySnapshotTool \
        --repository-root "$repo_root" \
        --output-root "$output_root"
}

case "$mode" in
    --record)
        run_renderer "$repo_root"
        echo "lm013-snapshots: recorded 12 canonical baselines"
        ;;
    --check)
        snapshot_tmp="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-lm013.XXXXXX")"
        case "$snapshot_tmp" in
            "${TMPDIR:-/tmp}"/deepshelves-lm013.*) ;;
            *) echo "Refusing unsafe temporary path: $snapshot_tmp" >&2; exit 1 ;;
        esac
        trap 'rm -rf "$snapshot_tmp"' EXIT
        run_renderer "$snapshot_tmp"
        diff -rq \
            "$repo_root/Results/LM-013/Baselines" \
            "$snapshot_tmp/Results/LM-013/Baselines"
        cmp \
            "$repo_root/Results/LM-013/snapshot-manifest.json" \
            "$snapshot_tmp/Results/LM-013/snapshot-manifest.json"
        cmp \
            "$repo_root/Results/LM-013/snapshot-index.html" \
            "$snapshot_tmp/Results/LM-013/snapshot-index.html"
        echo "lm013-snapshots: 12 baselines reproduce byte-for-byte with zero unapproved diffs"
        ;;
    *)
        echo "Usage: $0 [--record|--check]" >&2
        exit 64
        ;;
esac
