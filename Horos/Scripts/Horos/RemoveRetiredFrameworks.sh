#!/bin/sh
set -eu

# Removed embed phases leave these frameworks behind in incremental builds.
frameworks_path="${TARGET_BUILD_DIR:?}/${FRAMEWORKS_FOLDER_PATH:?}"
for framework in DCM Horos HorosAPI OsiriXAPI 'OsiriX Headers' HorosDCM; do
    rm -rf "$frameworks_path/$framework.framework"
done
