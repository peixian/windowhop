#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${SIGN_IDENTITY+x}" == "x" ]]; then
    signing_identity="$SIGN_IDENTITY"
elif [[ -f .signing-identity ]]; then
    signing_identity="$(cat .signing-identity)"
else
    signing_identity="-"
fi
if [[ -z "$signing_identity" || "$signing_identity" == *$'\n'* ]]; then
    echo "Signing identity must be a single nonempty line." >&2
    exit 1
fi
mkdir -p "$PWD/dist"
build_lock="$PWD/dist/.windowhop-build.lock"
if ! mkdir "$build_lock" 2>/dev/null; then
    echo "Another WindowHop build holds $build_lock. If it crashed, remove that empty directory and retry." >&2
    exit 1
fi
staging_dir=""
cleanup() {
    if [[ -n "$staging_dir" ]]; then rm -rf "$staging_dir"; fi
    rmdir "$build_lock"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
configuration="${CONFIGURATION:-release}"
swift_args=()
if [[ "${SWIFTPM_DISABLE_SANDBOX:-0}" == "1" ]]; then swift_args+=(--disable-sandbox); fi
swift build "${swift_args[@]}" -c "$configuration"
binary_path="$(swift build "${swift_args[@]}" -c "$configuration" --show-bin-path)"
staging_dir="$(mktemp -d "$PWD/dist/.windowhop-build.XXXXXX")"
app_path="$staging_dir/WindowHop.app"
installed_app="$PWD/dist/WindowHop.app"
mkdir -p "$app_path/Contents/MacOS" "$app_path/Contents/Resources"
cp Resources/Info.plist "$app_path/Contents/Info.plist"
cp Resources/AppIcon.icns "$app_path/Contents/Resources/AppIcon.icns"
cp "$binary_path/WindowHop" "$app_path/Contents/MacOS/WindowHop"
/usr/bin/codesign --force --sign "$signing_identity" "$app_path"
/usr/bin/codesign --verify --strict "$app_path"
# A missing key, denied Keychain prompt, or invalid certificate must leave the
# existing working app intact, never fall back to an ad-hoc signature.
if [[ -e "$installed_app" ]]; then mv "$installed_app" "$staging_dir/previous.app"; fi
if ! mv "$app_path" "$installed_app"; then
    if [[ -e "$staging_dir/previous.app" ]] && ! mv "$staging_dir/previous.app" "$installed_app"; then
        echo "Could not restore the old app. It is preserved at $staging_dir/previous.app" >&2
        staging_dir=""
    fi
    exit 1
fi
echo "Built $installed_app"
if [[ "$signing_identity" == "-" ]]; then
    echo "Ad-hoc signature: Accessibility permission may reset after rebuilding."
else
    echo "Signed with $signing_identity"
fi
