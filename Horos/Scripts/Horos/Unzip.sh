#!/bin/sh

cd "$SRCROOT/Binaries"
unzip -uo dciodvfy.zip

mkdir -p "$DERIVED_FILE_DIR"
touch "$DERIVED_FILE_DIR/UnzipBinaries.stamp"

exit 0
