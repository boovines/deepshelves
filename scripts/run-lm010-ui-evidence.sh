#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_directory=${1:-"$repo_root/Results/LM-010"}
derived_data="$repo_root/.build/LM010EvidenceDerivedData"
temporary_root=$(mktemp -d)
application_pid=''

cleanup() {
  if [[ -n "$application_pid" ]]; then
    kill "$application_pid" 2>/dev/null || true
  fi
  /bin/rm -rf -- "$temporary_root"
}
trap cleanup EXIT

mkdir -p "$output_directory"

"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec "$repo_root/project.yml" >/dev/null
xcodebuild \
  -project "$repo_root/LocalMemory.xcodeproj" \
  -scheme LocalMemoryApp \
  -configuration Release \
  -derivedDataPath "$derived_data" \
  -disableAutomaticPackageResolution \
  build \
  >"$temporary_root/build.log"

application_path="$derived_data/Build/Products/Release/Local Memory.app/Contents/MacOS/Local Memory"

capture_window() {
  local appearance=$1
  local size=$2
  local output_path="$output_directory/main-$appearance-$size.png"
  local case_root="$temporary_root/$appearance-$size"
  local runtime_state="$case_root/runtime-state.json"
  local navigation_state="$case_root/navigation-state.json"

  if [[ -e "$output_path" ]]; then
    echo "refusing to overwrite existing evidence: $output_path" >&2
    exit 2
  fi

  mkdir -p "$case_root"
  printf '%s\n' \
    '{"inspectorRequested":true,"section":"timeline","selectedMomentID":"00000000-0000-4000-8000-000000000102"}' \
    >"$navigation_state"
  chmod 0600 "$navigation_state"

  "$application_path" \
    --lm010-shell \
    --lm010-appearance "$appearance" \
    --lm010-window-size "$size" \
    --lm009-state-file "$runtime_state" \
    --lm010-navigation-state-file "$navigation_state" \
    >"$case_root/application.log" 2>&1 &
  application_pid=$!

  local window_id
  window_id=$(LM010_TARGET_PID="$application_pid" swift -e '
    import CoreGraphics
    import Foundation

    let targetPID = Int(ProcessInfo.processInfo.environment["LM010_TARGET_PID"]!)!
    for _ in 0..<80 {
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
    echo "Local Memory evidence window did not appear for $appearance/$size" >&2
    exit 3
  fi

  sleep 1
  /usr/sbin/screencapture -l"$window_id" -x "$output_path"
  chmod 0644 "$output_path"
  if [[ ! -s "$output_path" ]]; then
    echo "empty screenshot: $output_path" >&2
    exit 4
  fi

  kill "$application_pid" 2>/dev/null || true
  wait "$application_pid" 2>/dev/null || true
  application_pid=''
}

capture_settings() {
  local appearance=$1
  local output_path="$output_directory/settings-$appearance.png"
  local case_root="$temporary_root/settings-$appearance"
  local runtime_state="$case_root/runtime-state.json"
  local navigation_state="$case_root/navigation-state.json"

  if [[ -e "$output_path" ]]; then
    echo "refusing to overwrite existing evidence: $output_path" >&2
    exit 2
  fi

  mkdir -p "$case_root"

  "$application_path" \
    --lm010-open-settings \
    --lm010-appearance "$appearance" \
    --lm010-window-size default \
    --lm009-state-file "$runtime_state" \
    --lm010-navigation-state-file "$navigation_state" \
    >"$case_root/application.log" 2>&1 &
  application_pid=$!

  local window_id
  window_id=$(LM010_TARGET_PID="$application_pid" swift -e '
    import CoreGraphics
    import Foundation

    let targetPID = Int(ProcessInfo.processInfo.environment["LM010_TARGET_PID"]!)!
    for _ in 0..<100 {
        let rows = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        let windows = rows.compactMap { row -> (identifier: Int, width: CGFloat)? in
            guard (row[kCGWindowOwnerPID as String] as? Int) == targetPID,
                  (row[kCGWindowLayer as String] as? Int) == 0,
                  let identifier = row[kCGWindowNumber as String] as? Int,
                  let boundsValue = row[kCGWindowBounds as String],
                  let bounds = CGRect(
                    dictionaryRepresentation: boundsValue as! CFDictionary
                  ) else {
                return nil
            }
            return (identifier, bounds.width)
        }
        if windows.count >= 2, let settings = windows.min(by: { $0.width < $1.width }) {
            print(settings.identifier)
            exit(EXIT_SUCCESS)
        }
        usleep(100_000)
    }
    exit(EXIT_FAILURE)
  ')

  if [[ -z "$window_id" ]]; then
    echo "Local Memory Settings evidence window did not appear for $appearance" >&2
    exit 3
  fi

  sleep 1
  /usr/sbin/screencapture -l"$window_id" -x "$output_path"
  chmod 0644 "$output_path"
  if [[ ! -s "$output_path" ]]; then
    echo "empty screenshot: $output_path" >&2
    exit 4
  fi

  kill "$application_pid" 2>/dev/null || true
  wait "$application_pid" 2>/dev/null || true
  application_pid=''
}

capture_window light default
capture_window dark default
capture_window light minimum
capture_window dark minimum
capture_settings light
capture_settings dark

shasum -a 256 "$output_directory"/main-*.png "$output_directory"/settings-*.png
