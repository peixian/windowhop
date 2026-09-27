#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/windowhop-keyboard.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM

# Keeping the extension in the same temporary file exercises private filtering
# without exposing test hooks or installing a live event tap.
cat "$repo_root/Sources/WindowHop/KeyboardController.swift" \
    "$repo_root/Tests/KeyboardHarness.swift" > "$test_dir/main.swift"
swiftc -O -emit-library -emit-module -module-name WindowHopCore \
    "$repo_root/Sources/WindowHopCore/ShortcutConfiguration.swift" \
    -emit-module-path "$test_dir/WindowHopCore.swiftmodule" \
    -o "$test_dir/libWindowHopCore.dylib"
swiftc -O -I "$test_dir" -L "$test_dir" -lWindowHopCore \
    "$test_dir/main.swift" -o "$test_dir/keyboard-tests"
"$test_dir/keyboard-tests"
