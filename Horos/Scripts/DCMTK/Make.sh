#!/bin/sh

set -e; set -o xtrace

cmake_dir="$TARGET_TEMP_DIR/CMake"
install_dir="$TARGET_TEMP_DIR/Install"
copy_dir="$BUILT_PRODUCTS_DIR/DCMTK"

[ -d "${copy_dir}" ] && [ ! -f "${copy_dir}/.incomplete" ] && touch "$TARGET_TEMP_DIR/Make.stamp" && exit 0

mkdir -p "$install_dir"
mkdir -p "${copy_dir}"
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
