#!/bin/sh

set -e; set -o xtrace

source_dir="$PROJECT_DIR/$TARGET_NAME"
cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"

[ -d "$install_dir" ] && [ ! -f "$install_dir/.incomplete" ] && touch "$TARGET_TEMP_DIR/Make.stamp" && exit 0

mkdir -p "$install_dir"
touch "$install_dir/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"
export CC=clang
export CXX=clang

cd "$cmake_dir"
make "${args[@]}"
make install

# Grok 20.x may emit libgrokj2kcodec.a instead of libopenjp2.a.
# Keep Horos' expected archive name available in Install/lib.
if [ ! -f "$install_dir/lib/libopenjp2.a" ]; then
    if [ -f "$cmake_dir/bin/libopenjp2.a" ]; then
        rsync "$cmake_dir/bin/libopenjp2.a" "$install_dir/lib/"
    elif [ -f "$cmake_dir/src/lib/openjp2/libopenjp2.a" ]; then
        rsync "$cmake_dir/src/lib/openjp2/libopenjp2.a" "$install_dir/lib/"
    elif [ -f "$cmake_dir/lib/libgrokj2kcodec.a" ]; then
        rsync "$cmake_dir/lib/libgrokj2kcodec.a" "$install_dir/lib/libopenjp2.a"
    elif [ -f "$cmake_dir/bin/libgrokj2kcodec.a" ]; then
        rsync "$cmake_dir/bin/libgrokj2kcodec.a" "$install_dir/lib/libopenjp2.a"
    else
        echo >&2 "error: neither libopenjp2.a nor libgrokj2kcodec.a was produced by Grok"
        exit 1
    fi
fi
# Newer Grok releases removed this header from the old path.
# Prefer Grok's copy when present, otherwise reuse OpenJPEG's format_defs.h.
if [ -f "$source_dir/src/bin/common/format_defs.h" ]; then
    rsync "$source_dir/src/bin/common/format_defs.h" "$install_dir/include/OpenJPEG/"
else
    openjpeg_format_defs="$(dirname "$TARGET_TEMP_DIR")/OpenJPEG.build/Install/include/OpenJPEG/format_defs.h"
    if [ -f "$openjpeg_format_defs" ]; then
        rsync "$openjpeg_format_defs" "$install_dir/include/OpenJPEG/"
    else
        echo >&2 "warning: format_defs.h not found in Grok or OpenJPEG install; continuing"
    fi
fi

find "$install_dir/lib" -name 'libopenjp2*.dylib' -delete # in Grok, dylib is always built (argh), and on linking process XCode prefers the dylib. TODO: check if there is a flag to prioritize .a
find "$install_dir/lib" -name 'libgrokj2kcodec*.dylib' -delete

rm -f "$install_dir/.incomplete"
touch "$TARGET_TEMP_DIR/Make.stamp"

exit 0
