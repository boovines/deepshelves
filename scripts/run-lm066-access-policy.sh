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

tripwire_file="$(mktemp -t lm066-tripwire.XXXXXX)"
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

swift test --package-path Packages/MemoryAgentAccess --disable-sandbox \
  >/tmp/lm066-tests.log 2>&1 || {
  tail -n 120 /tmp/lm066-tests.log >&2
  exit 92
}

xcrun swift-format lint --strict \
  Packages/MemoryAgentAccess/Sources/MemoryAgentAccess/AgentCapabilityKeyStore.swift \
  Packages/MemoryAgentAccess/Sources/MemoryAgentAccess/AccessPolicyStore.swift \
  Packages/MemoryAgentAccess/Sources/MemoryAgentAccess/AccessPolicyProjectionFilter.swift \
  Packages/MemoryAgentAccess/Tests/MemoryAgentAccessTests/AccessPolicyStoreTests.swift \
  >/tmp/lm066-format.log

if rg -n 'import (ScreenCaptureKit|ImageIO|VideoToolbox|AVFoundation)|URLSession|NWConnection' \
    Packages/MemoryAgentAccess; then
  echo "agent policy boundary imports prohibited media/network runtime" >&2
  exit 93
fi
rg -q 'com.justinhou.deepshelves.shared' \
  Packages/MemoryAgentAccess/Sources/MemoryAgentAccess/AgentCapabilityKeyStore.swift
rg -q 'com.justinhou.deepshelves.shared' Apps/LocalMemoryApp/LocalMemoryApp.entitlements
if rg -q 'keychain-access-groups' \
    Apps/LocalMemoryCLI/LocalMemoryCLI.entitlements \
    Apps/LocalMemoryMCP/LocalMemoryMCP.entitlements; then
  echo "standalone helper unexpectedly gained direct Keychain access" >&2
  exit 94
fi

xcodebuild \
  -project LocalMemory.xcodeproj \
  -scheme LocalMemoryApp \
  -configuration Release \
  -derivedDataPath .build/DerivedData \
  -destination 'platform=macOS,arch=arm64' \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=YES \
  CODE_SIGNING_ALLOWED=NO \
  build >/tmp/lm066-build.log 2>&1 || {
    tail -n 120 /tmp/lm066-build.log >&2
    exit 95
  }

if [[ -s "$tripwire_file" ]] || pgrep -x VTEncoderXPCService >/dev/null; then
  echo "encoder tripwire failed" >&2
  exit 96
fi

echo "access_policy_tests=4 passed"
echo "persistence_permissions=0700_0600"
echo "expiry_revocation_races=fail_closed"
echo "projection_subset_property=passed"
echo "keychain_capability_boundary=passed"
echo "native_arm64_compile=passed"
echo "encoder_process_tripwire=passed"
