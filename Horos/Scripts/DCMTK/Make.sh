#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"
copy_dir="$BUILT_PRODUCTS_DIR/DCMTK"
copy_lib_dir="${copy_dir}/lib"
copy_include_dir="${copy_dir}/include"
bridge_src="$PROJECT_DIR/Horos/Sources/ModernDCMTKBridge.cpp"
bridge_output="${copy_dir}/libHorosModernDCMTKBridge.dylib"
cmake_cache="${cmake_dir}/CMakeCache.txt"

desired_modules="ofstd;oflog;oficonv;dcmdata;dcmimgle;dcmimage;dcmjpeg;dcmjpls;dcmtls;dcmnet;dcmsr;dcmsign;dcmwlm;dcmqrdb;dcmpstat;dcmrt;dcmiod;dcmfg;dcmseg;dcmtract;dcmpmap;dcmect;dcmapps"

if [ "$ONLY_ACTIVE_ARCH" = "YES" ] && [ -n "$NATIVE_ARCH_ACTUAL" ] && [ "$NATIVE_ARCH_ACTUAL" != "undefined_arch" ]; then
    desired_archs="$NATIVE_ARCH_ACTUAL"
else
    desired_archs=$(printf '%s' "$ARCHS" | tr ' ' ';')
    if [ -z "$desired_archs" ]; then
        desired_archs="$NATIVE_ARCH_ACTUAL"
    fi
fi

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

if [ -f "${cmake_cache}" ]; then
    current_archs="$(sed -n 's/^CMAKE_OSX_ARCHITECTURES:STRING=//p' "${cmake_cache}" | head -n 1)"
    current_modules="$(sed -n 's/^DCMTK_MODULES:STRING=//p' "${cmake_cache}" | head -n 1)"
    if [ "${current_archs}" != "${desired_archs}" ] || [ "${current_modules}" != "${desired_modules}" ]; then
        rm -f "$TARGET_TEMP_DIR/CMake.stamp"
        sh "$PROJECT_DIR/Horos/Scripts/$TARGET_NAME/CMake.sh"
    fi
fi

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
    dcmjpeg_lib="$(pick_lib dcmjpeg || true)"
    dcmjpls_lib="$(pick_lib dcmjpls || true)"
    dcmj2k_lib="$(pick_lib dcmj2k || true)"
    dcmrle_lib="$(pick_lib dcmrle || true)"
    ijg8_lib="$(pick_lib ijg8 || true)"
    ijg12_lib="$(pick_lib ijg12 || true)"
    ijg16_lib="$(pick_lib ijg16 || true)"
    dcmtkcharls_lib="$(pick_lib dcmtkcharls || true)"
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
    if [ -n "${dcmjpeg_lib}" ]; then
        bridge_link_args+=("${dcmjpeg_lib}")
    fi
    if [ -n "${dcmjpls_lib}" ]; then
        bridge_link_args+=("${dcmjpls_lib}")
    fi
    if [ -n "${dcmj2k_lib}" ]; then
        bridge_link_args+=("${dcmj2k_lib}")
    fi
    if [ -n "${dcmrle_lib}" ]; then
        bridge_link_args+=("${dcmrle_lib}")
    fi
    if [ -n "${ijg8_lib}" ]; then
        bridge_link_args+=("${ijg8_lib}")
    fi
    if [ -n "${ijg12_lib}" ]; then
        bridge_link_args+=("${ijg12_lib}")
    fi
    if [ -n "${ijg16_lib}" ]; then
        bridge_link_args+=("${ijg16_lib}")
    fi
    if [ -n "${dcmtkcharls_lib}" ]; then
        bridge_link_args+=("${dcmtkcharls_lib}")
    fi
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
