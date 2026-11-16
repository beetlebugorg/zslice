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
    vec3 n = normalize(vnormal);
    vec3 l = normalize(pc.light.xyz);
    vec3 v = normalize(pc.eye.xyz - vpos);
    vec3 base = toLinear(vcolor);
    if (vhigh > 0.5) base = mix(base, vec3(1.0, 0.85, 0.1), 0.65);
    // More light from the sky (up) than from the ground.
    float ambient = mix(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    vec3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18;
    vec3 c = base * (ambient + 0.85 * diffuse) + vec3(spec);
    // Out of focus: pale and flat, so the beads in focus stand out.
    if (vfocus < 0.5) c = mix(c, vec3(0.80), 0.82);
    frag = vec4(toSrgb(c), 1.0);
}
