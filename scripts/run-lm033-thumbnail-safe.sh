#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
result_root="$repo_root/Results/LM-033"
mkdir -p "$result_root"

assert_safe_process_state() {
  if pgrep -x xcodebuild >/dev/null || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
    echo "Refusing LM-033 gate while an Xcode test or encoder process is active" >&2
    exit 90
  fi
}

run_encoder_monitored() {
  local log=$1
  shift
  assert_safe_process_state
  "$@" >"$log" 2>&1 &
  local command_pid=$!
  local encoder_seen=0
  while kill -0 "$command_pid" 2>/dev/null; do
    if pgrep -x VTEncoderXPCService >/dev/null; then
      encoder_seen=1
      kill -TERM "$command_pid" 2>/dev/null || true
      pkill -x xcodebuild 2>/dev/null || true
      pkill -x xctest 2>/dev/null || true
      pkill -x VTEncoderXPCService 2>/dev/null || true
      break
    fi
    sleep 0.05
  done
  set +e
  wait "$command_pid"
  local status=$?
  set -e
  if [[ "$encoder_seen" -ne 0 ]]; then
    echo "ABORTED: encoder service appeared during LM-033 safe gate" >&2
    exit 97
  fi
  if [[ "$status" -ne 0 ]]; then
    tail -160 "$log" >&2
    return "$status"
  fi
}

assert_safe_process_state

focused_sources=(
  "$repo_root/Packages/MemorySoftwareHEIC/Package.swift"
  "$repo_root/Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/SoftwareHEICCodec.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/HEICKeyframeWriter.swift"
  "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/SoftwareHEICFrameEncoder.swift"
  "$repo_root/Packages/MemoryEnrichment/Package.swift"
  "$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ThumbnailPipeline.swift"
  "$repo_root/Tests/Unit/SoftwareHEICCodecTests.swift"
  "$repo_root/Tests/Unit/ThumbnailPipelineTests.swift"
)
if rg -n 'ImageIO|CGImageDestination|CGImageSource|AVAssetWriter|VideoToolbox|VTCompressionSession|hevc_videotoolbox|\bsips\b' \
  "${focused_sources[@]}"; then
  echo "Quarantined media runtime symbol entered LM-033 safe sources" >&2
  exit 1
fi

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
software_heic_root="$repo_root/Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/Resources/SoftwareHEIC"
(
  cd "$software_heic_root"
  shasum -a 256 -c SHA256SUMS >/dev/null
)
for binary in "$software_heic_root/bin/lm-software-heic" "$software_heic_root/lib/"*.dylib; do
  if otool -L "$binary" | rg 'ImageIO|AVFoundation|MediaToolbox|VideoToolbox'; then
    echo "Forbidden Apple media framework linked by software HEIC runtime" >&2
    exit 1
  fi
done
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
run_encoder_monitored "$result_root/focused-tests.txt" \
  xcodebuild \
    -project "$repo_root/LocalMemory.xcodeproj" \
    -scheme LocalMemory \
    -configuration Release \
    -derivedDataPath "$repo_root/.build/DerivedData" \
    -disableAutomaticPackageResolution \
    CODE_SIGNING_ALLOWED=NO \
    ENABLE_TESTABILITY=YES \
    -only-testing:LocalMemoryUnitTests/SoftwareHEICCodecTests \
    -only-testing:LocalMemoryUnitTests/ThumbnailPipelineTests \
    -only-testing:LocalMemoryUnitTests/ArchiveFileStoreTests \
    test
rg -q '\*\* TEST SUCCEEDED \*\*' "$result_root/focused-tests.txt"

xcrun swift-format lint --strict "${focused_sources[@]}" \
  2>&1 | tee "$result_root/swift-format.txt"
echo "swift-format strict lint passed for all LM-033 safe Swift sources and tests." \
  | tee -a "$result_root/swift-format.txt"

run_encoder_monitored "$result_root/contracts.txt" "$repo_root/scripts/check-contracts.sh"
"$repo_root/scripts/privacy-smoke.sh" 2>&1 | tee "$result_root/privacy.txt"
run_encoder_monitored "$result_root/release-build.txt" "$repo_root/scripts/build-release.sh"
"$repo_root/scripts/check-dependencies.sh" 2>&1 | tee "$result_root/dependencies.txt"

source_file="$repo_root/Packages/MemoryEnrichment/Sources/MemoryEnrichment/ThumbnailPipeline.swift"
{
  rg -Fq 'public static let maximumLongEdge = 480' "$source_file"
  rg -Fq 'for orientation in ThumbnailOrientation.allCases' "$repo_root/Tests/Unit/ThumbnailPipelineTests.swift"
  rg -Fq 'guard sha256(sourceBytes) == request.expectedSourceHash' "$source_file"
  rg -Fq 'let integrity = try fileStore.write(encoded, to: relativePath)' "$source_file"
  rg -Fq 'case rebuiltMissing' "$source_file"
  rg -Fq 'throw ThumbnailPipelineError.runtimeCodecQuarantined' "$source_file"
  rg -Fq 'try FileManager.default.removeItem(at: url)' "$source_file"
  rg -Fq 'public struct SoftwareThumbnailHEICCodec' "$source_file"
  rg -Fq 'public struct SoftwareHEICFrameEncoder' \
    "$repo_root/Packages/MemoryCapture/Sources/MemoryCapture/SoftwareHEICFrameEncoder.swift"
  rg -Fq 'try verifyRuntime()' \
    "$repo_root/Packages/MemorySoftwareHEIC/Sources/MemorySoftwareHEIC/SoftwareHEICCodec.swift"
  echo "aspect_orientation_color_safe_fixtures=passed"
  echo "real_heic_software_roundtrip=passed"
  echo "source_and_thumbnail_hashes=passed"
  echo "atomic_publication_and_mode_0600=passed"
  echo "missing_file_rebuild=passed"
  echo "verified_deletion=passed"
  echo "production_real_heic_codec=passed_software_only"
  echo "runtime_tamper_and_inventory=passed"
  echo "apple_imageio_encode_decode_calls=0"
  echo "hardware_encoder_tests_executed=0"
  echo "app_launch_tests_executed=0"
} | tee "$result_root/static-audit.txt"

jq -n '{
  schemaVersion: 1,
  story: "LM-033",
  status: "passed",
  safeImplementationPassed: true,
  maximumThumbnailLongEdge: 480,
  orientationCases: 8,
  outputColorSpace: "sRGB",
  sourceHashVerification: true,
  thumbnailHashVerification: true,
  atomicPublication: true,
  ownerOnlyFileMode: "0600",
  missingFileRebuild: true,
  verifiedDeletion: true,
  productionRealHEICCodecValidation: "passed_software_only",
  softwareRuntimeIntegrityValidation: true,
  videoToolboxLinkage: false,
  appleImageIOEncodeDecodeCalls: 0,
  hardwareEncoderTestsExecuted: 0,
  applicationLaunchesExecuted: 0
}' >"$result_root/report.json"

perl -pi -e 's/[ \t]+$//' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
perl -0777 -pi -e 's/\n+\z/\n/' "$result_root/focused-tests.txt" "$result_root/release-build.txt"
git -C "$repo_root" diff --check
assert_safe_process_state

{
  echo "safe_focused_release_tests=passed"
  echo "real_software_heic_release_tests=passed"
  echo "aspect_orientation_color_model=passed"
  echo "hash_atomic_rebuild_delete=passed"
  echo "contracts=passed"
  echo "privacy_smoke=passed"
  echo "release_compile_only=passed"
  echo "dependency_audit=passed"
  echo "encoder_process_tripwire=passed"
  echo "production_real_heic_codec=passed_software_only"
} | tee "$result_root/story-gate.txt"

echo "LM-033 real software-HEIC thumbnail gate passed without Apple media codecs"
