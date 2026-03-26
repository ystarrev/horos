#!/bin/sh

set -e; set -o xtrace

source_dir="$PROJECT_DIR/$TARGET_NAME"
cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

[ -d "$install_dir" ] && [ ! -f "$install_dir/.incomplete" ] && exit 0

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"
export CC=clang
export CXX=clang

cd "$cmake_dir"
make "${args[@]}"
make install

# Grok's output path changed; keep a static archive in Install/lib without
# assuming one specific build-tree location.
if [ ! -f "$install_dir/lib/libopenjp2.a" ]; then
    if [ -f "$cmake_dir/bin/libopenjp2.a" ]; then
        rsync "$cmake_dir/bin/libopenjp2.a" "$install_dir/lib/"
    elif [ -f "$cmake_dir/src/lib/openjp2/libopenjp2.a" ]; then
        rsync "$cmake_dir/src/lib/openjp2/libopenjp2.a" "$install_dir/lib/"
    else
        echo >&2 "error: libopenjp2.a was not produced by Grok"
        exit 1
    fi
fi
rsync "$source_dir/src/bin/common/format_defs.h" "$install_dir/include/OpenJPEG/"     # we need this header

find "$install_dir/lib" -name 'libopenjp2*.dylib' -delete # in Grok, dylib is always built (argh), and on linking process XCode prefers the dylib. TODO: check if there is a flag to prioritize .a

rm -f "$install_dir/.incomplete"

exit 0
