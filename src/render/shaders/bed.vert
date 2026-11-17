// The bed model of the printer: a static mesh under the plate. See
// src/bed.zig for the vertices, and src/render/view.zig for the push
// constants.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(location = 0) in vec3 pos;
layout(location = 1) in vec3 normal;
layout(location = 2) in vec2 uv;

layout(push_constant) uniform Push {
    mat4 mvp;    // with the move of the bed center to the middle of the bed
    vec4 color;  // rgb: the color of the bed
    vec4 light;  // xyz: the direction to the light
    vec4 params; // x: 1 with a texture, y: the z over which the bed is
                 // see-through, z: 1 when the camera is under the bed
} pc;

layout(location = 0) out vec3 vnormal;
layout(location = 1) out vec2 vuv;
layout(location = 2) out float vz;

void main() {
    gl_Position = pc.mvp * vec4(pos, 1.0);
    vnormal = normal;
    vuv = uv;
    vz = pos.z;
}
