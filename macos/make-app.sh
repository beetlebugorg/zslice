#!/bin/sh
# Makes build/zslice.app from the Swift package: the binary, Info.plist
# (the document types for STL and 3MF files), and an ad-hoc signature.
# Run build-core.sh first. CONFIG is debug or release (default).
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")"
CONFIG=${CONFIG:-release}
swift build -c "$CONFIG" --arch arm64 --arch x86_64 2>/dev/null || swift build -c "$CONFIG"
bin=$(swift build -c "$CONFIG" --show-bin-path)
app=build/zslice.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/ZSlice" "$app/Contents/MacOS/zslice"
cp Info.plist "$app/Contents/Info.plist"
codesign --force --sign - "$app"
echo "$app"
