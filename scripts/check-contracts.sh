#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/deepshelves-contracts.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

swiftc \
    -parse-as-library \
    -module-name ContractFixtureGenerator \
    Packages/MemoryContracts/Sources/MemoryContracts/*.swift \
    Benchmarks/ContractFixtureGenerator.swift \
    -o "$work_dir/contract-fixture-generator"
"$work_dir/contract-fixture-generator" "$work_dir/v1"
diff -ru Fixtures/Contracts/v1 "$work_dir/v1"

while IFS=$'\t' read -r relative_path expected_hash; do
    actual_hash="$(shasum -a 256 "Fixtures/$relative_path" | awk '{print $1}')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        echo "Fixture hash mismatch: $relative_path" >&2
        exit 1
    fi
done < <(jq -r '.fixtures[] | [.path, .sha256] | @tsv' Fixtures/manifest.json)

xcodegen generate --spec project.yml >/dev/null
xcodebuild \
    -quiet \
    -project LocalMemory.xcodeproj \
    -scheme LocalMemory \
    -configuration Debug \
    -derivedDataPath .build/DerivedData \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    test \
    -only-testing:LocalMemoryUnitTests/MemoryContractsV1Tests \
    -only-testing:LocalMemoryUnitTests/ContractFixtureCompatibilityTests

echo "check-contracts: 11 canonical V1 fixtures reproduce byte-for-byte and all contract validation tests pass"
