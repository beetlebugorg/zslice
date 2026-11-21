// The mesh of the Paint tool: the color of the filament of each triangle,
// with the light of web/app/gl.js (paintFrag). A lit triangle (the region
// under the pointer, or the selection) mixes with blue. A hidden triangle
// (split into pieces that draw on their own) draws nothing.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 color;
    vec4 light;
    vec4 params;
} pc;

layout(location = 0) in vec3 vnormal;
layout(location = 1) flat in uint vrgb;
layout(location = 2) flat in uint vflags;

layout(location = 0) out vec4 frag;

void main() {
    if ((vflags & 2u) != 0u) discard;
    vec3 c = vec3(float((vrgb >> 16) & 255u), float((vrgb >> 8) & 255u), float(vrgb & 255u)) / 255.0;
    vec3 n = normalize(vnormal);
    float lit = 0.45 + 0.55 * max(dot(n, normalize(pc.light.xyz)), 0.0) + 0.15 * abs(n.z);
    vec3 col = c * min(lit, 1.0);
    if ((vflags & 1u) != 0u) col = mix(col, vec3(0.2, 0.55, 1.0), 0.45);
    frag = vec4(col, 1.0);
}
