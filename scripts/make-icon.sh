#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
icon_tmp="$(mktemp -d "${TMPDIR:-/tmp}/windowhop-icon.XXXXXX")"
trap 'rm -rf "$icon_tmp"' EXIT
iconset="$icon_tmp/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    /usr/bin/sips -z "$size" "$size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double_size=$((size * 2))
    /usr/bin/sips -z "$double_size" "$double_size" Resources/AppIcon.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
/usr/bin/iconutil --convert icns --output Resources/AppIcon.icns "$iconset"
echo "Packaged Resources/AppIcon.icns"
