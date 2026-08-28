#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root=${1:-"$repo_root/Results/LM-025"}
safe_log="$result_root/safe-tests.txt"
build_log="$result_root/swift-build.txt"
audit_log="$result_root/source-audit.txt"
binary="$repo_root/.build/LM025Safe/lm025-media-writer-core-harness"

mkdir -p "$result_root" "$(dirname "$binary")"

if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
  || pgrep -f '(^|/)LocalMemoryIntegrationTests( |$)' >/dev/null; then
  echo "Refusing LM-025 safe gate while an Xcode test process is active" >&2
  exit 1
fi

safe_sources=(
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MemoryCapture.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MediaWriterCore.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MediaChunkPublisher.swift"
  "$repo_root/Tests/Pure/LM025MediaWriterCoreHarness.swift"
)

if rg -n 'AVFoundation|VideoToolbox|AVAssetWriter|HEVCMediaWriter' "${safe_sources[@]}"; then
  echo "Unsafe media framework or production encoder reference entered the pure LM-025 gate" >&2
  exit 1
fi

{
  echo "process_guard=passed"
  echo "pure_source_encoder_scan=passed"
  xcrun swiftc "${safe_sources[@]}" -o "$binary"
  "$binary"
} 2>&1 | tee "$safe_log"

swift build --package-path "$repo_root/Packages/MemoryCapture" 2>&1 | tee "$build_log"

writer_source="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEVCMediaWriter.swift"
integration_source="$repo_root/Tests/Integration/CaptureMediaIntegrationTests.swift"
{
  if rg -n 'AVAssetWriterInputPixelBufferAdaptor' "$writer_source"; then
    echo "AVAssetWriterInputPixelBufferAdaptor remains in production writer" >&2
    exit 1
  fi
  rg -n 'input\.append\(encodedSample\)' "$writer_source"
  rg -n 'kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder.*true' \
    "$writer_source"
  rg -n 'LM-025 hardware HEVC quarantine' "$integration_source"
  rg -n 'Do not remove this skip until the hardware/OS gate is explicitly re-authorized' \
    "$integration_source"
  echo "sample_buffer_append_path=passed"
  echo "hardware_requirement_preserved=passed"
  echo "integration_hardware_quarantine=passed"
} 2>&1 | tee "$audit_log"

echo "LM-025 safe static, pure-core, publisher, and compile-only gates passed"
