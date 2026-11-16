#!/bin/sh
# Compile the GLSL shaders of the renderer to SPIR-V.
#
# The .spv files are committed, so a normal build needs no shader compiler.
# Run this after a change to a shader in src/render/shaders/.
# Needs glslangValidator (the Khronos reference compiler).
#
# SPDX-License-Identifier: AGPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../src/render/shaders"
for f in *.vert *.frag; do
    glslangValidator -V "$f" -o "$f.spv" >/dev/null
    echo "compiled $f"
done
