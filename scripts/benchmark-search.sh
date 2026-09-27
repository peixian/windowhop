#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "$0")/.." && pwd)"
benchmark_dir="$(mktemp -d "${TMPDIR:-/tmp}/windowhop-search.XXXXXX")"
trap 'rm -rf "$benchmark_dir"' EXIT
swiftc -O -whole-module-optimization -parse-as-library -emit-library -emit-module \
    -module-name WindowHopCore -emit-module-path "$benchmark_dir/WindowHopCore.swiftmodule" \
    "$repo_dir"/Sources/WindowHopCore/*.swift \
    -o "$benchmark_dir/libWindowHopCore.dylib"
# Match the app's module boundary, and stop optimization from eliminating pairs
# of public session operations whose final state happens to equal their input.
swiftc -O -parse-as-library -D PREPARED_SEARCH -D SEARCH_CORE_MODULE \
    -I "$benchmark_dir" -L "$benchmark_dir" -lWindowHopCore \
    -Xlinker -rpath -Xlinker "$benchmark_dir" \
    "$repo_dir/scripts/benchmark-search.swift" \
    -o "$benchmark_dir/search-benchmark"
"$benchmark_dir/search-benchmark" "$@"
