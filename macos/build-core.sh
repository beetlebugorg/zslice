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
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The two builds run at the same time: most of a release build is the
# code generation of LLVM for the one object, which uses about one core,
# so the second build takes cores that are free.
for arch in aarch64 x86_64; do
    "$ZIG" build lib -Dtarget="$arch-macos" -Doptimize="$OPT" -Dcompiler-rt --prefix "zig-out/macos-$arch" >"$tmp/$arch.log" 2>&1 &
    echo $! >"$tmp/$arch.pid"
done
failed=0
for arch in aarch64 x86_64; do
    if ! wait "$(cat "$tmp/$arch.pid")"; then
        cat "$tmp/$arch.log" >&2
        failed=1
    fi
done
[ "$failed" = 0 ] || exit 1
for arch in aarch64 x86_64; do
    # The archive of Zig 0.16 does not align its object to 8 bytes, and
    # the Apple tools (ld, lipo, libtool) then skip it. So the script takes
    # the object out and makes the archive again with libtool.
    mkdir "$tmp/$arch"
    (cd "$tmp/$arch" && ar x "$OLDPWD/zig-out/macos-$arch/lib/libzslice.a" && chmod 644 ./*.o)
    libtool -static -o "$tmp/$arch.a" "$tmp/$arch"/*.o
done
lipo -create "$tmp/aarch64.a" "$tmp/x86_64.a" -output "$tmp/libzslice.a"
# The same library keeps its time, so a build of Xcode does not link again.
cmp -s "$tmp/libzslice.a" "$out/libzslice.a" || cp "$tmp/libzslice.a" "$out/libzslice.a"
echo "$out/libzslice.a"
