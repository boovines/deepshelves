#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root=${1:-"$repo_root/Results/LM-025"}
safe_log="$result_root/safe-tests.txt"
build_log="$result_root/swift-build.txt"
audit_log="$result_root/source-audit.txt"
termination_log="$result_root/software-termination.txt"
binary="$repo_root/.build/LM025Safe/lm025-media-writer-core-harness"
termination_root=""
termination_pid=""

cleanup() {
  if [[ -n "$termination_pid" ]] && kill -0 "$termination_pid" 2>/dev/null; then
    kill -9 "$termination_pid" 2>/dev/null || true
    wait "$termination_pid" 2>/dev/null || true
  fi
  if [[ -n "$termination_root" && -d "$termination_root" ]]; then
    rm -rf -- "$termination_root"
  fi
}
trap cleanup EXIT

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

termination_root=$(mktemp -d "$repo_root/.build/LM025Safe/termination.XXXXXX")
termination_partial="$termination_root/.chunk.mov.partial.mov"
termination_output="$termination_root/chunk.mov"
termination_ready="$termination_root/ready"
{
  "$binary" --termination-child "$termination_partial" "$termination_ready" &
  termination_pid=$!
  for _ in {1..100}; do
    if [[ -s "$termination_ready" ]]; then
      break
    fi
    if ! kill -0 "$termination_pid" 2>/dev/null; then
      echo "Mock software encoder child exited before termination point" >&2
      exit 1
    fi
    sleep 0.05
  done
  test -s "$termination_ready"
  kill -9 "$termination_pid"
  wait "$termination_pid" 2>/dev/null || true
  termination_pid=""
  test -s "$termination_partial"
  test ! -e "$termination_output"
  shasum -a 256 "$termination_partial"
  rm -- "$termination_partial" "$termination_ready"
  test ! -e "$termination_output"
  echo "mock_software_mid_write_termination=passed"
  echo "partial_recovery_without_final_visibility=passed"
} 2>&1 | tee "$termination_log"

swift build --package-path "$repo_root/Packages/MemoryCapture" 2>&1 | tee "$build_log"

writer_source="$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEVCMediaWriter.swift"
integration_source="$repo_root/Tests/Integration/CaptureMediaIntegrationTests.swift"
{
  rg -n 'AVAssetWriterInputPixelBufferAdaptor' "$writer_source"
  rg -n 'adaptor\.pixelBufferPool' "$writer_source"
  rg -n 'adaptor\.append\(adaptorBuffer' "$writer_source"
  rg -n 'retainedAdaptorBuffers\.retainAccepted\(adaptorBuffer\)' "$writer_source"
  rg -n 'defer \{ retainedAdaptorBuffers\.releaseAfterFinalization\(\) \}' "$writer_source"
  if rg -n 'input\.append\(' "$writer_source"; then
    echo "Direct sample-buffer append bypasses the adaptor pool" >&2
    exit 1
  fi
  if rg -n 'guard sourceDimensions != dimensions' "$writer_source"; then
    echo "Same-size source bypasses the adaptor-pool copy" >&2
    exit 1
  fi
  test "$(rg -c 'adaptor\.append\(' "$writer_source")" -eq 1
  rg -n 'kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder.*true' \
    "$writer_source"
  rg -n 'LM-025 hardware HEVC quarantine' "$integration_source"
  rg -n 'Do not remove this skip until the hardware/OS gate is explicitly re-authorized' \
    "$integration_source"
  echo "every_frame_uses_adaptor_pool=passed"
  echo "accepted_adaptor_buffers_retained_through_finalization=passed"
  echo "hardware_requirement_preserved=passed"
  echo "integration_hardware_quarantine=passed"
} 2>&1 | tee "$audit_log"

echo "LM-025 safe core, mock-software, termination, publisher, and compile-only gates passed"
