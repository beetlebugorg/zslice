// The decals of the labels of the Label tool (see View.addLabel in
// src/render/view.zig): a flat color, with no light, as the web draws
// them. The color comes in the normal, the alpha in uv.x. The vertex
// shader is bed.vert.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(location = 0) in vec3 vnormal;
layout(location = 1) in vec2 vuv;
layout(location = 2) in float vz;

layout(location = 0) out vec4 frag;

void main() {
    frag = vec4(vnormal, vuv.x);
}
