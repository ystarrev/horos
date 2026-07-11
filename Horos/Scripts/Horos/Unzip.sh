#!/bin/sh

cd "$SRCROOT/Binaries"
unzip -uo PAGES.zip
unzip -uo OsiriXReport.template.zip
# unzip -uo FeedbackReporter.framework.zip
unzip -uo dciodvfy.zip
unzip -uo Ming.zip

cd "$SRCROOT/Binaries/EmbeddedPlugins"
#unzip -uo HorosCloud.horosplugin.zip

cd "$SRCROOT/Binaries/PAGES"
rm ._*

mkdir -p "$DERIVED_FILE_DIR"
touch "$DERIVED_FILE_DIR/UnzipBinaries.stamp"

exit 0
