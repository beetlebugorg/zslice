// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
    vec4 eye;
    vec4 params;
} pc;

layout(location = 0) out vec4 frag;

void main() {
    frag = vec4(pc.color.rgb, 1.0);
}
