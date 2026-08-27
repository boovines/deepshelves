#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"

xcodegen generate --spec project.yml
xcodebuild \
    -project LocalMemory.xcodeproj \
    -scheme LocalMemory \
    -configuration Debug \
    -derivedDataPath .build/DerivedData \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    test

