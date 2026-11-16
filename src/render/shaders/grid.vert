// The bed outline and grid lines.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(location = 0) in vec3 pos;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
    vec4 eye;
    vec4 params;
} pc;

void main() {
    gl_Position = pc.mvp * vec4(pos, 1.0);
}
