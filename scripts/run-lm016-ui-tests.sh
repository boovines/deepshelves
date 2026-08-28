#!/bin/bash
set -euo pipefail

repo_root=$(cd "$(dirname "$0")/.." && pwd)
output_path=${1:-"$repo_root/Results/LM-016/ui-tests.txt"}

if [[ -e "$output_path" ]]; then
  echo "refusing to overwrite existing UI-test evidence: $output_path" >&2
  exit 2
fi

cd "$repo_root"
"$repo_root/scripts/materialize-dependencies.sh" >/dev/null
xcodegen generate --spec project.yml >/dev/null

set -o pipefail
xcodebuild \
  -project LocalMemory.xcodeproj \
  -scheme LocalMemory-UI \
  -configuration Release \
  -derivedDataPath .build/LM010DerivedData \
  -disableAutomaticPackageResolution \
  -only-testing:LocalMemoryUITests/AppCompositionUITests \
  -only-testing:LocalMemoryUITests/BootstrapUITests \
  -only-testing:LocalMemoryUITests/MainShellUITests \
  -only-testing:LocalMemoryUITests/OnboardingUITests \
  -only-testing:LocalMemoryUITests/GlobalSearchPanelUITests \
  -only-testing:LocalMemoryUITests/ShellAccessibilityUITests \
  test 2>&1 | tee "$output_path"
