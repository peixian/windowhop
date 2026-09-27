#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${CONFIGURATION:-release}"
swift_args=()
if [[ "${SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then swift_args+=(--disable-sandbox); fi
swift build "${swift_args[@]}" -c "$configuration"
binary_path="$(swift build "${swift_args[@]}" -c "$configuration" --show-bin-path)"
app_path="$PWD/dist/WindowHop.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp "$binary_path/WindowHop" "$app_path/Contents/MacOS/WindowHop"
/usr/bin/codesign --force --sign "${SIGN_IDENTITY:--}" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
echo "Built $app_path"
