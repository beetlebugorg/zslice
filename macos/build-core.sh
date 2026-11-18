#!/bin/sh
# Builds the Zig core as one universal static library, lib/libzslice.a,
# for arm64 and x86_64 Macs. ZIG names the Zig 0.16 compiler.
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
ZIG=${ZIG:-zig}
OPT=${OPT:-ReleaseFast}
out=macos/lib
mkdir -p "$out"
for arch in aarch64 x86_64; do
    "$ZIG" build lib -Dtarget="$arch-macos" -Doptimize="$OPT" --prefix "zig-out/macos-$arch"
done
lipo -create zig-out/macos-aarch64/lib/libzslice.a zig-out/macos-x86_64/lib/libzslice.a -output "$out/libzslice.a"
echo "$out/libzslice.a"
