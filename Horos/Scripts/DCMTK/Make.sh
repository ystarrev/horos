#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"
copy_dir="$BUILT_PRODUCTS_DIR/DCMTK"
copy_lib_dir="${copy_dir}/lib"
copy_include_dir="${copy_dir}/include"
bridge_src="$PROJECT_DIR/Horos/Sources/ModernDCMTKBridge.cpp"
bridge_output="${copy_dir}/libHorosModernDCMTKBridge.dylib"

if [ -d "${copy_dir}" ] && [ ! -f "${copy_dir}/.incomplete" ]; then
    if [ ! -f "${bridge_src}" ] || { [ -f "${bridge_output}" ] && [ "${bridge_src}" -ot "${bridge_output}" ]; }; then
        touch "$TARGET_TEMP_DIR/Make.stamp"
        exit 0
    fi
fi

mkdir -p "$install_dir"
mkdir -p "${copy_dir}"
mkdir -p "${copy_lib_dir}"
mkdir -p "${copy_include_dir}"
touch "${copy_dir}/.incomplete"

args=()
export MAKEFLAGS="-j $(sysctl -n hw.ncpu)"

echo "${cmake_dir}"
cd "$cmake_dir"
make "${args[@]}" install

# Copy subset of applications to build directory
#
cp "${install_dir}/bin/dcmdump" "${copy_dir}"
cp "${install_dir}/bin/dcmpsprt" "${copy_dir}"
cp "${install_dir}/bin/dcmprscu" "${copy_dir}"
cp "${install_dir}/bin/dsr2html" "${copy_dir}"
cp "${install_dir}/bin/echoscu" "${copy_dir}"

pick_lib() {
    local name="$1"
    if [ -f "${install_dir}/lib/lib${name}.a" ]; then
        printf '%s\n' "${install_dir}/lib/lib${name}.a"
        return 0
    fi
    if [ -f "${install_dir}/lib/lib${name}.dylib" ]; then
        printf '%s\n' "${install_dir}/lib/lib${name}.dylib"
        return 0
    fi
    return 1
}

if [ -f "${bridge_src}" ]; then
    dcmsr_lib="$(pick_lib dcmsr)"
    dcmdata_lib="$(pick_lib dcmdata)"
    dcmimgle_lib="$(pick_lib dcmimgle)"
    dcmimage_lib="$(pick_lib dcmimage)"
    ofstd_lib="$(pick_lib ofstd)"
    oflog_lib="$(pick_lib oflog)"
    oficonv_lib="$(pick_lib oficonv || true)"

    bridge_link_args=(
        "${dcmsr_lib}"
        "${dcmdata_lib}"
        "${dcmimgle_lib}"
        "${dcmimage_lib}"
        "${ofstd_lib}"
        "${oflog_lib}"
    )
    if [ -n "${oficonv_lib}" ]; then
        bridge_link_args+=("${oficonv_lib}")
    fi

    c++ -dynamiclib -std=c++17 -fPIC \
        -I"${install_dir}/include" \
        -I"${install_dir}/include/dcmtk" \
        "${bridge_src}" \
        "${bridge_link_args[@]}" \
        -liconv -lz -lxml2 \
        -Wl,-install_name,@rpath/libHorosModernDCMTKBridge.dylib \
        -o "${bridge_output}"
fi

# Copy libraries and headers so app targets can start migrating to
# modern in-process DCMTK without depending on the old vendored source tree.
#
if [ -d "${install_dir}/lib" ]; then
    find "${install_dir}/lib" -maxdepth 1 \( -name 'lib*.a' -o -name 'lib*.dylib' \) -exec cp {} "${copy_lib_dir}" \;
fi

if [ -d "${install_dir}/include" ]; then
    rm -rf "${copy_include_dir}"
    mkdir -p "${copy_include_dir}"
    cp -R "${install_dir}/include/." "${copy_include_dir}"
fi

dicom_dict="${install_dir}/share/dcmtk/dicom.dic"
if [ ! -f "$dicom_dict" ]; then
    dicom_dict="$(find "${install_dir}/share" -maxdepth 2 -type f -name dicom.dic | head -n 1)"
fi
if [ -z "$dicom_dict" ] || [ ! -f "$dicom_dict" ]; then
    echo >&2 "error: unable to locate dicom.dic in ${install_dir}/share"
    exit 1
fi
cp "$dicom_dict" "${copy_dir}"

rm -f "$copy_dir/.incomplete"
touch "$TARGET_TEMP_DIR/Make.stamp"

exit 0
