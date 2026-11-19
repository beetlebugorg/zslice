#!/bin/sh
# Makes build/zslice.app from the Swift package: the binary, Info.plist
# (the document types for STL and 3MF files), and an ad-hoc signature.
# Run build-core.sh first. CONFIG is debug or release (default).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")"
# The Xcode project lists each Swift file (XcodeGen writes the list): a new
# file must be in it too, or Xcode does not build. Run "xcodegen generate".
missing=$(find Sources/ZSlice QuickLook -name '*.swift' -exec basename {} \; | while read -r f; do
    grep -q "$f" ZSlice.xcodeproj/project.pbxproj || echo "$f"
done)
if [ -n "$missing" ]; then
    echo "make-app.sh: not in ZSlice.xcodeproj: $missing. Run xcodegen generate." >&2
    exit 1
fi
CONFIG=${CONFIG:-release}
# The Command Line Tools have no SwiftUI macro plugin (@State), so the
# build uses Xcode when it is there.
if [ -z "${DEVELOPER_DIR:-}" ] && [ -d /Applications/Xcode.app ]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
swift build -c "$CONFIG" --arch arm64 --arch x86_64 2>/dev/null || swift build -c "$CONFIG"
bin=$(swift build -c "$CONFIG" --show-bin-path)
app=build/zslice.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/ZSlice" "$app/Contents/MacOS/zslice"
cp Info.plist "$app/Contents/Info.plist"
# The bed models of the printers (src/printers/beds; see REFERENCES.md).
cp -R ../src/printers/beds "$app/Contents/Resources/beds"
codesign --force --sign - "$app"
echo "$app"
