#!/bin/bash
set -euo pipefail

repo_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repo_root"
manifest="Dependencies/dependencies.json"
mode="${1:---static}"

if [[ "$mode" != "--static" && "$mode" != "--binaries" ]]; then
    echo "Usage: $0 --static|--binaries" >&2
    exit 64
fi

jq -e '
    .schemaVersion == 1 and
    .policy.automaticUpdates == "forbidden" and
    .policy.postInstallScripts == "forbidden" and
    .policy.runtimeDependencyDownloads == "forbidden" and
    .policy.runtimeModelDownloads == "forbidden" and
    (.components | length > 0) and
    ([.components[].id] | length == (unique | length)) and
    (all(.components[];
        (.version | length > 0) and
        (.scope == "systemProvided" or (.revision | length >= 7)) and
        (.source | length > 0) and
        (.license.sha256 | test("^[0-9a-f]{64}$")) and
        (.license.expectedSize > 0) and
        (.updateProcedure | length > 0) and
        all(.artifacts[];
            .expectedSize > 0 and
            (.sha256 | test("^[0-9a-f]{64}$")) and
            (.url | length > 0)))) and
    (all(.components[] | select(.networkCapable == true);
        .scope == "forbiddenShipping" and (.linkedShippingTargets | length == 0)))
' "$manifest" >/dev/null

required_ids=(
    argmax-oss-swift
    coreml-mobileclip-s0
    grdb-sqlcipher
    mcp-swift-sdk
    sqlcipher-swift
    swift-testing-toolchain
    whisperkit-small-en
    xcodegen
    xctest-toolchain
    xcuitest-toolchain
)
for component in "${required_ids[@]}"; do
    jq -e --arg id "$component" 'any(.components[]; .id == $id)' "$manifest" >/dev/null
done

expected_xcodegen="$(tr -d '[:space:]' < .xcodegen-version)"
manifest_xcodegen="$(jq -r '.components[] | select(.id == "xcodegen") | .version' "$manifest")"
[[ "$manifest_xcodegen" == "$expected_xcodegen" ]]
rg -q "minimumXcodeGenVersion: $expected_xcodegen" project.yml

actual_xcode="$(xcodebuild -version | sed -n '1s/^Xcode //p')"
actual_xcode_build="$(xcodebuild -version | sed -n '2s/^Build version //p')"
[[ "$actual_xcode" == "$(jq -r '.buildEnvironment.xcodeVersion' "$manifest")" ]]
[[ "$actual_xcode_build" == "$(jq -r '.buildEnvironment.xcodeBuild' "$manifest")" ]]

developer_root="$(xcode-select -p)"
sdk_root="$(xcrun --sdk macosx --show-sdk-path)"
toolchain_artifacts=(
    "coreml-toolchain|$sdk_root/System/Library/Frameworks/CoreML.framework/Versions/A/CoreML.tbd"
    "swift-testing-toolchain|$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks/Testing.framework/Versions/A/Testing"
    "xctest-toolchain|$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCTest.framework/Versions/A/XCTest"
    "xcuitest-toolchain|$developer_root/Platforms/MacOSX.platform/Developer/Library/Frameworks/XCUIAutomation.framework/Versions/A/XCUIAutomation"
)
for item in "${toolchain_artifacts[@]}"; do
    component="${item%%|*}"
    path="${item#*|}"
    expected_size="$(jq -r --arg id "$component" '.components[] | select(.id == $id) | .artifacts[0].expectedSize' "$manifest")"
    expected_hash="$(jq -r --arg id "$component" '.components[] | select(.id == $id) | .artifacts[0].sha256' "$manifest")"
    [[ "$(stat -f '%z' "$path")" == "$expected_size" ]]
    [[ "$(shasum -a 256 "$path" | awk '{print $1}')" == "$expected_hash" ]]
done

if rg -n 'Sparkle|Sentry|TelemetryDeck|Firebase|EventSource|NIOHTTP|HuggingFace|WhisperKit' \
    project.yml Apps Packages --glob '*.swift' --glob 'Package.swift'; then
    echo "Forbidden update, telemetry, network transport, or remote-model package in shipping graph." >&2
    exit 1
fi

if [[ "$mode" == "--binaries" ]]; then
    release_root=".build/DerivedData/Build/Products/Release"
    binaries=(
        "$release_root/Local Memory.app/Contents/MacOS/Local Memory"
        "$release_root/local-memory"
        "$release_root/local-memory-mcp"
    )
    forbidden_binary='Sparkle|Sentry|TelemetryDeck|Firebase|EventSource|NIOHTTP|HuggingFace|WhisperKit'
    for binary in "${binaries[@]}"; do
        [[ -x "$binary" ]]
        if otool -L "$binary" | rg -i "$forbidden_binary"; then
            echo "Forbidden dependency linked by $binary" >&2
            exit 1
        fi
        if strings "$binary" | rg -i "$forbidden_binary"; then
            echo "Forbidden dependency marker embedded in $binary" >&2
            exit 1
        fi
    done
fi

if [[ "$mode" == "--binaries" ]]; then
    echo "dependency-audit: manifest, toolchain, static shipping graph, and release binaries verified"
else
    echo "dependency-audit: manifest, toolchain, and static shipping graph verified"
fi
