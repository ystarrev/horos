#!/bin/sh

path="$( cd "$(dirname "${BASH_SOURCE[0]}")" && pwd )/$(basename "${BASH_SOURCE[0]}")"
cd "$TARGET_NAME"; pwd

set -e; set -o xtrace

ARCHS="$ARCHS" xcodebuild -derivedDataPath "$TARGET_TEMP_DIR" -scheme "FeedbackReporter" -configuration Release MACOSX_DEPLOYMENT_TARGET="$MACOSX_DEPLOYMENT_TARGET" build

cp -R "$TARGET_TEMP_DIR/Build/Products/Release/FeedbackReporter.framework" "$BUILT_PRODUCTS_DIR"

exit 0
