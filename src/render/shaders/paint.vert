// The mesh of the Paint tool (see View.setPaintMesh in src/render/view.zig):
// the triangles of a part, each in the color of its filament. A vertex is
// a bed vertex (src/bed.zig); its uv has two integers: the color
// 0xRRGGBB, and the flags (1: lit, 2: hidden).
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 normal;
layout(location = 2) in uvec2 info;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;  // not used
    vec4 light;  // xyz: the direction to the light
    vec4 params; // not used
} pc;

layout(location = 0) out vec3 vnormal;
layout(location = 1) flat out uint vrgb;
layout(location = 2) flat out uint vflags;

void main() {
    gl_Position = pc.mvp * vec4(pos, 1.0);
    vnormal = normal;
    vrgb = info.x;
    vflags = info.y;
}
