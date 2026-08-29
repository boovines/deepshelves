#!/bin/bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$repository_root"

if pgrep -x xcodebuild >/dev/null \
    || pgrep -x xctest >/dev/null \
    || pgrep -x VTEncoderXPCService >/dev/null; then
  echo "unsafe pre-existing build/test/encoder process" >&2
  exit 90
fi

tripwire_file="$(mktemp -t lm065-tripwire.XXXXXX)"
tripwire_pid=""

cleanup() {
  if [[ -n "$tripwire_pid" ]]; then
    kill "$tripwire_pid" 2>/dev/null || true
    wait "$tripwire_pid" 2>/dev/null || true
  fi
  rm -f "$tripwire_file"
}
trap cleanup EXIT INT TERM

(
  while true; do
    if pgrep -x VTEncoderXPCService >/dev/null; then
      echo "VTEncoderXPCService appeared" >"$tripwire_file"
      while IFS= read -r encoder_pid; do
        kill "$encoder_pid" 2>/dev/null || true
      done < <(pgrep -x VTEncoderXPCService || true)
      exit 91
    fi
    sleep 0.05
  done
) &
tripwire_pid=$!

swift test --package-path Packages/SharedQueryKit --disable-sandbox >/tmp/lm065-tests.log 2>&1 || {
  tail -n 120 /tmp/lm065-tests.log >&2
  exit 95
}

xcrun swift-format lint --strict \
  Packages/SharedQueryKit/Sources/SharedQueryKit/SharedQueryKit.swift \
  Packages/SharedQueryKit/Tests/SharedQueryKitTests/SharedQueryServiceTests.swift \
  Apps/LocalMemoryApp/SearchPresentation.swift \
  Apps/LocalMemoryCLI/LocalMemoryCLI.swift \
  Apps/LocalMemoryMCP/LocalMemoryMCP.swift >/tmp/lm065-format.log

if rg -n 'import (ScreenCaptureKit|ImageIO|VideoToolbox|AVFoundation)' \
    Packages/SharedQueryKit Apps/LocalMemoryCLI Apps/LocalMemoryMCP; then
  echo "shared/helper read path imports a prohibited media runtime" >&2
  exit 92
fi
if rg -n 'Memory(Search|Store)' \
    Packages/SharedQueryKit/Package.swift \
    Packages/SharedQueryKit/Sources; then
  echo "shared query contract depends on an app/storage implementation package" >&2
  exit 96
fi

for target in Apps/LocalMemoryApp Apps/LocalMemoryCLI Apps/LocalMemoryMCP; do
  rg -q 'import SharedQueryKit' "$target"
done
rg -q 'SharedQueryService' Apps/LocalMemoryApp/SearchPresentation.swift

xcodebuild \
  -project LocalMemory.xcodeproj \
  -scheme LocalMemory \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/lm065-build.log 2>&1 || {
    tail -n 120 /tmp/lm065-build.log >&2
    exit 93
  }

if [[ -s "$tripwire_file" ]] || pgrep -x VTEncoderXPCService >/dev/null; then
  echo "encoder tripwire failed" >&2
  exit 94
fi

echo "shared_query_tests=2 passed"
echo "app_helper_projection=byte_equivalent"
echo "changed_file_format=passed"
echo "prohibited_media_imports=absent"
echo "native_arm64_compile=passed"
echo "encoder_process_tripwire=passed"
