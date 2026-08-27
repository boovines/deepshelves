#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

tool_path="$repo_root/.build/contract-fixture-generator"
swiftc \
    -parse-as-library \
    -module-name ContractFixtureGenerator \
    Packages/MemoryContracts/Sources/MemoryContracts/*.swift \
    Benchmarks/ContractFixtureGenerator.swift \
    -o "$tool_path"
"$tool_path" "$repo_root/Fixtures/Contracts/v1"

echo "generate-contract-fixtures: wrote canonical V1 contract fixtures"
