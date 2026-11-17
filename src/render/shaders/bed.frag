// The bed model: a soft gray with a little light, the texture over it at
// part strength, so the bed does not fight the colors of the print. The
// parts of the model over the plate (a frame, a back plate) and the whole
// bed from under it are see-through.
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
    vec3 n = normalize(vnormal);
    // Both sides of a face: the files do not agree on the winding.
    float lit = 0.7 + 0.3 * abs(dot(n, normalize(pc.light.xyz)));
    vec3 col = pc.color.rgb * lit;
    if (pc.params.x > 0.5 && vuv.x > -0.5) {
        vec4 t = texture(tex, vuv);
        col = mix(col, t.rgb * lit, t.a * 0.7);
    }
    float a = (vz > pc.params.y || pc.params.z > 0.5) ? 0.3 : 1.0;
    frag = vec4(col, a);
}
