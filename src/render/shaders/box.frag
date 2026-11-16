// Light for a bead of plastic: a sky and ground ambient term, a diffuse
// term, and a soft specular term for the slight gloss of PLA. The math is
// in linear color space: the colors come in as sRGB values and go out as
// sRGB values (the swapchain format is UNORM).
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 light;
    vec4 eye;
    vec4 params;
} pc;

layout(location = 0) in vec3 vcolor;
layout(location = 1) in vec3 vnormal;
layout(location = 2) in vec3 vpos;
layout(location = 3) in float vhigh;
layout(location = 4) in float vfocus;
layout(location = 0) out vec4 frag;

vec3 toLinear(vec3 c) { return pow(c, vec3(2.2)); }
vec3 toSrgb(vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }

void main() {
    // A focus (params.z != 0) draws in two passes: the beads in focus,
    // solid (params.w < 2), then the other beads as faint ghosts that do
    // not hide what is behind them (params.w = 2, blended, no depth write).
    bool focus = pc.params.z > 0.5;
    if (focus && pc.params.w > 1.5) {
        if (vfocus > 0.5) discard;
        float rim = 1.0 - abs(dot(normalize(vnormal), normalize(pc.eye.xyz - vpos)));
        frag = vec4(vec3(0.55, 0.58, 0.62), 0.03 + 0.09 * rim);
        return;
    }
    if (focus && vfocus < 0.5) discard;
    vec3 n = normalize(vnormal);
    vec3 l = normalize(pc.light.xyz);
    vec3 v = normalize(pc.eye.xyz - vpos);
    vec3 base = toLinear(vcolor);
    // A selection (params.x < params.y): the selected path in a strong
    // yellow, and all other beads in a neutral gray, so the selection is
    // the only color in the view.
    if (pc.params.y > pc.params.x) {
        base = vhigh > 0.5 ? toLinear(vec3(1.0, 0.78, 0.05)) : toLinear(vec3(0.74, 0.75, 0.77));
    }
    // More light from the sky (up) than from the ground.
    float ambient = mix(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    vec3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18;
    vec3 c = base * (ambient + 0.85 * diffuse) + vec3(spec);
    frag = vec4(toSrgb(c), 1.0);
}
