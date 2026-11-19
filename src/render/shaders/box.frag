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
layout(location = 5) in vec4 vsec;
layout(location = 6) in vec3 vend;
layout(location = 0) out vec4 frag;

vec3 toLinear(vec3 c) { return pow(c, vec3(2.2)); }
vec3 toSrgb(vec3 c) { return pow(clamp(c, 0.0, 1.0), vec3(1.0 / 2.2)); }

void main() {
    vec3 v = normalize(pc.eye.xyz - vpos);
    vec3 n = normalize(vnormal);
    // The mean normal of the part of the bead that the eye sees: the view
    // direction in the cross section.
    vec3 sd = vec3(vsec.xy, 0.0);
    vec3 ev = normalize(sd * dot(v, sd) + vec3(0.0, 0.0, v.z + 1e-4));
    if (vsec.w > 0.0) {
        // A ribbon: round ends, and the normal of the bead at the place
        // across it (t). vnormal is ac of box.vert: across the ribbon.
        float t = 2.0 * vsec.z;
        float o = min(min(vend.x, vend.y), 0.0);
        if (o * o + t * t > 1.0) discard;
        // The bead seen from the eye: a round side, the flat top (or
        // bottom) face, and the other round side. u: the place on a
        // round side, from its middle (-1 to 1).
        float r = vsec.w;
        float f = vend.z;
        vec3 ac = normalize(vnormal);
        vec3 zf = vec3(0.0, 0.0, ev.z < 0.0 ? -1.0 : 1.0);
        float zac = dot(zf, ac);
        float x = t * (f + r);
        float u = 0.0;
        n = zf;
        if (x > f + r * zac) u = clamp((x - f) / r, -1.0, 1.0);
        else if (x < r * zac - f) u = clamp((x + f) / r, -1.0, 1.0);
        if (u != 0.0) n = normalize(ev * sqrt(max(1.0 - u * u, 0.0)) + ac * u);
    }
    // A far bead is a pixel or two across. Its round shading (a bright
    // ridge, dark grooves) then beats against the pixel grid (moire). So
    // under 5 pixels the normal goes toward ev, and the gloss fades. A
    // far wall then looks even.
    float px = 1.0 / max(fwidth(vsec.z), 1e-6);
    float flat_k = 1.0 - smoothstep(2.0, 5.0, px);
    // A focus (params.z != 0) draws in two passes: the beads in focus,
    // solid (params.w < 2), then the other beads as faint ghosts that do
    // not hide what is behind them (params.w = 2, blended, no depth write).
    bool focus = pc.params.z > 0.5 || pc.params.z < -0.5;
    if (focus && pc.params.w > 1.5) {
        if (vfocus > 0.5) discard;
        float rim = 1.0 - abs(dot(n, v));
        frag = vec4(vec3(0.55, 0.58, 0.62), 0.03 + 0.09 * rim);
        return;
    }
    if (focus && vfocus < 0.5) discard;
    vec3 l = normalize(pc.light.xyz);
    vec3 base = toLinear(vcolor);
    // A selection (params.x < params.y): the selected path in a strong
    // yellow. The other beads keep their colors (to fade them, the view
    // isolates the selection: params.z < 0).
    // A print view (params.w = 4): params.x to params.y are the beads of
    // the top layer (a print view has no selection).
    bool lit = pc.params.w > 3.5;
    if (!lit && pc.params.y > pc.params.x && vhigh > 0.5) {
        base = toLinear(vec3(1.0, 0.78, 0.05));
    }
    // More light from the sky (up) than from the ground.
    float ambient = mix(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    vec3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18 * (1.0 - flat_k);
    vec3 c = base * (ambient + 0.85 * diffuse) + vec3(spec);
    // A print view: the top layer is lit, and the layers under it are
    // darker, so the layer that prints now stands out.
    if (lit) c = vhigh > 0.5 ? c * 1.12 + base * 0.10 : c * 0.70;
    // The toolhead of a replay (params.w = 3): lit, and see-through, with a
    // brighter rim so its shape shows.
    if (pc.params.w > 2.5 && pc.params.w < 3.5) {
        float rim = 1.0 - abs(dot(n, v));
        frag = vec4(toSrgb(c + vec3(0.25 * rim * rim)), 0.38 + 0.3 * rim);
        return;
    }
    // A plate whose slice is old, or that cannot slice (the Vulkan
    // backend; light.w): the colors fade to the background, as the web
    // does.
    frag = vec4(mix(toSrgb(c), vec3(0.965, 0.969, 0.973), pc.light.w), 1.0);
}
