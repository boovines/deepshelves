#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_path=${1:-"$repo_root/Results/LM-009/LM-009.mov"}
derived_data="$repo_root/.build/LM009EvidenceDerivedData"
temporary_root=$(mktemp -d)
state_path="$temporary_root/runtime-state.json"
application_pid=''

cleanup() {
  if [[ -n "$application_pid" ]]; then
    kill "$application_pid" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT

if [[ -e "$output_path" ]]; then
  echo "refusing to overwrite existing evidence: $output_path" >&2
  exit 2
fi

mkdir -p "$(dirname "$output_path")"

xcodebuild \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemoryApp \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  build \
  >"$temporary_root/build.log"

application_path="$derived_data/Build/Products/Release/Local Memory.app/Contents/MacOS/Local Memory"
"$application_path" \
  --lm009-evidence-sequence \
  --lm009-state-file "$state_path" \
  --lm009-runtime recording \
  >"$temporary_root/application.log" 2>&1 &
application_pid=$!

window_id=$(LM009_TARGET_PID="$application_pid" swift -e '
  import CoreGraphics
  import Foundation

  let targetPID = Int(ProcessInfo.processInfo.environment["LM009_TARGET_PID"]!)!
  for _ in 0..<50 {
      let rows = CGWindowListCopyWindowInfo(
          [.optionOnScreenOnly, .excludeDesktopElements],
          kCGNullWindowID
      ) as? [[String: Any]] ?? []
      if let row = rows.first(where: {
          ($0[kCGWindowOwnerPID as String] as? Int) == targetPID
              && ($0[kCGWindowLayer as String] as? Int) == 0
      }), let identifier = row[kCGWindowNumber as String] as? Int {
          print(identifier)
          exit(EXIT_SUCCESS)
      }
      usleep(100_000)
  }
  exit(EXIT_FAILURE)
')

if [[ -z "$window_id" ]]; then
  echo "Local Memory evidence window did not appear" >&2
  exit 3
fi

# Window-id capture excludes the desktop and every other application. The
# synthetic sequence contains no archive or personal content.
/usr/sbin/screencapture -v -l"$window_id" -V9 -x "$output_path"
chmod 0644 "$output_path"

if [[ ! -s "$output_path" ]]; then
  echo "screen recording is empty: $output_path" >&2
  exit 4
fi

shasum -a 256 "$output_path"
