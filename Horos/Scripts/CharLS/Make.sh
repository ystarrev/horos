#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

[ -d "$install_dir" ] && [ ! -f "$install_dir/.incomplete" ] && touch "$TARGET_TEMP_DIR/Make.stamp" && exit 0

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

args=()
jobs="$(sysctl -n hw.ncpu 2>/dev/null || true)"
[ -n "$jobs" ] || jobs=1
export MAKEFLAGS="-j $jobs"
export CC=clang
export CXX=clang++

cd "$cmake_dir"
make "${args[@]}"
make install

rm -f "$install_dir/.incomplete"
touch "$TARGET_TEMP_DIR/Make.stamp"

exit 0
