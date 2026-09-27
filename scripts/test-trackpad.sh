#!/bin/sh
set -eu
repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_dir=$(mktemp -d "${TMPDIR:-/tmp}/windowhop-trackpad.XXXXXX")
trap 'rm -rf "$test_dir"' EXIT HUP INT TERM
cat "$repo_root/Sources/WindowHop/TrackpadGestureController.swift" \
    "$repo_root/Tests/TrackpadHarness.swift" > "$test_dir/main.swift"
swiftc -O -emit-library -emit-module -module-name WindowHopCore \
    "$repo_root/Sources/WindowHopCore/TrackpadGestureState.swift" \
    -emit-module-path "$test_dir/WindowHopCore.swiftmodule" \
    -o "$test_dir/libWindowHopCore.dylib"
swiftc -O -I "$test_dir" -L "$test_dir" -lWindowHopCore \
    "$test_dir/main.swift" -o "$test_dir/trackpad-tests"
"$test_dir/trackpad-tests"
