#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root=${1:-"$repo_root/Results/LM-025"}
build_root="$repo_root/.build/LM025HEICSafe"
safe_log="$result_root/safe-tests.txt"
build_log="$result_root/swift-build.txt"
audit_log="$result_root/source-audit.txt"
termination_log="$result_root/software-termination.txt"
contract_log="$result_root/contracts.txt"
integration_log="$result_root/fake-integration-tests.txt"
termination_root=""
termination_pid=""
watcher_pid=""

cleanup() {
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  if [[ -n "$termination_pid" ]] && kill -0 "$termination_pid" 2>/dev/null; then
    kill -9 "$termination_pid" 2>/dev/null || true
    wait "$termination_pid" 2>/dev/null || true
  fi
  if [[ -n "$termination_root" && -d "$termination_root" ]]; then
    rm -rf -- "$termination_root"
  fi
}
trap cleanup EXIT

guard_processes() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-025 safe gate while a test or video-encoder process is active" >&2
    exit 90
  fi
}

start_encoder_tripwire() {
  (
    while true; do
      if pgrep -x VTEncoderXPCService >/dev/null; then
        pkill -x VTEncoderXPCService 2>/dev/null || true
        echo "VideoToolbox encoder service appeared during safe gate" > "$result_root/ENCODER-TRIPWIRE-FAILED"
        exit 91
      fi
      sleep 0.05
    done
  ) &
  watcher_pid=$!
}

stop_encoder_tripwire() {
  if [[ -n "$watcher_pid" ]] && kill -0 "$watcher_pid" 2>/dev/null; then
    kill "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  fi
  watcher_pid=""
  test ! -e "$result_root/ENCODER-TRIPWIRE-FAILED"
  test -z "$(pgrep -x VTEncoderXPCService || true)"
}

mkdir -p "$result_root" "$build_root"
rm -f -- "$result_root/ENCODER-TRIPWIRE-FAILED"
guard_processes
"$repo_root/scripts/materialize-dependencies.sh" >/dev/null

unsafe_pattern='AVAssetWriter|AVVideoCodecType[.]hevc|VTCompressionSession|VideoToolbox|HEVCMediaWriter'
if rg -n "$unsafe_pattern" \
  "$repo_root/Packages/MemoryCapture/Sources" \
  "$repo_root/Apps/LocalMemoryApp/CaptureSpikeHarness.swift"; then
  echo "Quarantined hardware video encoder reference remains in the shipping capture path" >&2
  exit 1
fi

{
  xcrun swiftc -emit-library -emit-module \
    -module-name MemoryContracts \
    "$repo_root"/Packages/MemoryContracts/Sources/MemoryContracts/*.swift \
    -o "$build_root/libMemoryContracts.dylib" \
    -emit-module-path "$build_root/MemoryContracts.swiftmodule"
  xcrun swiftc -emit-library -emit-module \
    -module-name MemoryCapture \
    -I "$build_root" -L "$build_root" -lMemoryContracts \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MemoryCapture.swift" \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MediaWriterCore.swift" \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/MediaChunkPublisher.swift" \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift" \
    -o "$build_root/libMemoryCapture.dylib" \
    -emit-module-path "$build_root/MemoryCapture.swiftmodule"
  xcrun swiftc -parse-as-library \
    -I "$build_root" -L "$build_root" -lMemoryContracts -lMemoryCapture \
    "$repo_root/Tests/Pure/LM025HEICKeyframeHarness.swift" \
    -o "$build_root/lm025-heic-keyframe-harness"
  DYLD_LIBRARY_PATH="$build_root" "$build_root/lm025-heic-keyframe-harness"
  echo "pure_boundary_encoder=passed"
  echo "scope_identity_manifest_integrity=passed"
  echo "atomic_directory_faults=passed"
  echo "retained_only_republication=passed"
  echo "forensic_sentinel_absence=passed"
} 2>&1 | tee "$safe_log"

termination_root=$(mktemp -d "$build_root/termination.XXXXXX")
termination_output="$termination_root/chunk"
termination_ready="$termination_root/ready"
{
  DYLD_LIBRARY_PATH="$build_root" "$build_root/lm025-heic-keyframe-harness" \
    --termination-child "$termination_output" "$termination_ready" &
  termination_pid=$!
  for _ in {1..100}; do
    if [[ -s "$termination_ready" ]]; then
      break
    fi
    if ! kill -0 "$termination_pid" 2>/dev/null; then
      echo "Fake HEIC boundary child exited before the termination point" >&2
      exit 1
    fi
    sleep 0.05
  done
  test -s "$termination_ready"
  kill -9 "$termination_pid"
  wait "$termination_pid" 2>/dev/null || true
  termination_pid=""
  test ! -e "$termination_output"
  staging="$termination_root/.chunk.partial"
  test -d "$staging/frames"
  test "$(find "$staging/frames" -type f -name '*.heic' | wc -l | tr -d ' ')" -eq 1
  test ! -e "$staging/manifest.json"
  rm -rf -- "$staging"
  test ! -e "$termination_output"
  echo "mock_boundary_mid_write_termination=passed"
  echo "incomplete_staging_never_visible=passed"
} 2>&1 | tee "$termination_log"

guard_processes
start_encoder_tripwire
swift build --package-path "$repo_root/Packages/MemoryCapture" 2>&1 | tee "$build_log"
stop_encoder_tripwire

guard_processes
start_encoder_tripwire
xcodebuild \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemory \
  -configuration Debug \
  -derivedDataPath "$repo_root/.build/DerivedData" \
  -disableAutomaticPackageResolution \
  CODE_SIGNING_ALLOWED=NO \
  -only-testing:LocalMemoryUnitTests/SoftwareHEICCodecTests \
  -only-testing:LocalMemoryIntegrationTests/CaptureMediaIntegrationTests \
  test 2>&1 | tee "$integration_log"
stop_encoder_tripwire

guard_processes
start_encoder_tripwire
"$repo_root/scripts/check-contracts.sh" 2>&1 | tee "$contract_log"
stop_encoder_tripwire

{
  test ! -e "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEVCMediaWriter.swift"
  if rg -n 'import ImageIO|CGImageDestination|CGImageSource' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture"; then
    echo "Apple ImageIO remains in the shipping capture path" >&2
    exit 1
  fi
  rg -n 'SoftwareHEICFrameEncoder' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/SoftwareHEICFrameEncoder.swift"
  software_heic_root="$repo_root/Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/Resources/SoftwareHEIC"
  (cd "$software_heic_root" && shasum -a 256 -c SHA256SUMS >/dev/null)
  for binary in "$software_heic_root/bin/lm-software-heic" "$software_heic_root/lib/"*.dylib; do
    if otool -L "$binary" | rg 'ImageIO|AVFoundation|MediaToolbox|VideoToolbox'; then
      exit 1
    fi
  done
  rg -n 'HEICKeyframeManifest' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"
  rg -n 'renamex_np' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"
  rg -n 'SafeFakeHEICEncoder' \
    "$repo_root/Tests/Integration/CaptureMediaIntegrationTests.swift"
  if rg -n 'ImageIOHEICFrameEncoder[(]' \
    "$repo_root/Tests"; then
    echo "A test constructs the production HEIC encoder boundary" >&2
    exit 1
  fi
  if rg -n 'URLSession|Network[.]|NWConnection|socket[(]|connect[(]' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"; then
    echo "Network capability entered the local media writer" >&2
    exit 1
  fi
  echo "hardware_video_encoder_removed=passed"
  echo "production_software_heic_roundtrip=passed"
  echo "boundary_fake_fault_tests=passed"
  echo "local_only_writer_scan=passed"
  echo "encoder_process_tripwire=passed"
} 2>&1 | tee "$audit_log"

perl -pi -e 's/[ \t]+$//' "$integration_log" "$build_log"
perl -0777 -pi -e 's/\n+\z/\n/' "$integration_log" "$build_log"
git -C "$repo_root" diff --check

echo "LM-025 HEIC keyframe safe gate passed without hardware video encoding"
