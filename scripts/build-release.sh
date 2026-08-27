#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

"$repo_root/scripts/materialize-dependencies.sh"
expected_version="$(tr -d '[:space:]' < .xcodegen-version)"
actual_version="$(xcodegen --version)"
if [[ "$actual_version" != "Version: $expected_version" && "$actual_version" != "$expected_version" ]]; then
    echo "Expected XcodeGen $expected_version, found $actual_version" >&2
    exit 1
fi

xcodegen generate --spec project.yml
xcodebuild \
    -project LocalMemory.xcodeproj \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath .build/DerivedData \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    build
