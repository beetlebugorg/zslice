#!/bin/sh
# Build the Zig core and put its archive and headers where meson wants them.
#
# usage: build-core.sh <core-root> <optimize> <out-libzslice.a> <out-zslice.h> <out-zslice-app.h>
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu

core_root=$1
optimize=$2
out_a=$3
out_h=$4
out_app_h=$5

prefix=$(dirname "$out_a")/core-prefix

# The core is for the CPU of this machine. ZSLICE_CORE_CPU sets another
# CPU model: the release sets "baseline", so the app runs on any x86_64 or
# aarch64 CPU.
zig build lib \
  --build-file "$core_root/build.zig" \
  -Doptimize="$optimize" \
  ${ZSLICE_CORE_CPU:+-Dcpu="$ZSLICE_CORE_CPU"} \
  --prefix "$prefix"

cp -f "$prefix/lib/libzslice.a" "$out_a"
cp -f "$prefix/include/zslice.h" "$out_h"
cp -f "$prefix/include/zslice-app.h" "$out_app_h"
