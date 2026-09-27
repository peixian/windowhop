#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/windowhop-displays.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# This requires an interactive macOS WindowServer session. It briefly presents
# its own demo panels on the connected displays; it does not inspect other apps
# or post synthetic input. Private test hooks never enter the production target.
cat "$repo_root/Sources/WindowHop/SwitcherPanel.swift" \
    "$repo_root/Sources/WindowHop/SwitcherPanels.swift" \
    "$repo_root/Tests/DisplayHarness.swift" > "$test_dir/main.swift"
swiftc -O -whole-module-optimization -parse-as-library -emit-library -emit-module \
    -module-name WindowHopCore -emit-module-path "$test_dir/WindowHopCore.swiftmodule" \
    "$repo_root"/Sources/WindowHopCore/*.swift \
    -o "$test_dir/libWindowHopCore.dylib"
swiftc -O -I "$test_dir" -L "$test_dir" -lWindowHopCore \
    -Xlinker -rpath -Xlinker "$test_dir" \
    "$test_dir/main.swift" -o "$test_dir/display-tests"
"$test_dir/display-tests"
