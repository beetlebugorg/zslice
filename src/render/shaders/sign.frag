// The signs of the plates (see View.setSigns in src/render/view.zig): the
// image that the shell draws, with the alpha of the sign from the normal
// (x). The vertex shader is bed.vert.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
    vec4 light;
    vec4 params;
} pc;

layout(set = 0, binding = 0) uniform sampler2D tex;

layout(location = 0) in vec3 vnormal;
layout(location = 1) in vec2 vuv;
layout(location = 2) in float vz;

layout(location = 0) out vec4 frag;

void main() {
    vec4 t = texture(tex, vuv);
    float a = t.a * vnormal.x;
    if (a < 0.004) discard;
    frag = vec4(t.rgb, a);
}
