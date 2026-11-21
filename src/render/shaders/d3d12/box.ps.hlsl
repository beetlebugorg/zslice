// The HLSL form of shaders/box.frag: light for a bead of plastic. The math
// is in linear color space: the colors come in as sRGB values and go out as
// sRGB values (the target format is UNORM). Keep the two files the same.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 light;
    float4 eye;
    float4 params;
};

struct PsIn {
    float4 position : SV_Position;
    float3 vcolor : TEXCOORD0;
    float3 vnormal : TEXCOORD1;
    float3 vpos : TEXCOORD2;
    float vhigh : TEXCOORD3;
    float vfocus : TEXCOORD4;
    float4 vsec : TEXCOORD5;
    float3 vend : TEXCOORD6;
};

float3 toLinear(float3 c) { return pow(abs(c), 2.2); }
float3 toSrgb(float3 c) { return pow(saturate(c), 1.0 / 2.2); }

float4 main(PsIn i) : SV_Target {
    float3 v = normalize(eye.xyz - i.vpos);
    float3 n = normalize(i.vnormal);
    // The mean normal of the part of the bead that the eye sees: the view
    // direction in the cross section.
    float3 sd = float3(i.vsec.xy, 0.0);
    float3 ev = normalize(sd * dot(v, sd) + float3(0.0, 0.0, v.z + 1e-4));
    // Before the discards: a derivative needs the pixels around this one.
    float px = 1.0 / max(fwidth(i.vsec.z), 1e-6);
    if (i.vsec.w > 0.0) {
        // A ribbon: round ends, and the normal of the bead at the place
        // across it (t). vnormal is ac of the vertex shader.
        float t = 2.0 * i.vsec.z;
        float o = min(min(i.vend.x, i.vend.y), 0.0);
        if (o * o + t * t > 1.0) discard;
        // The bead seen from the eye: a round side, the flat top (or
        // bottom) face, and the other round side.
        float r = i.vsec.w;
        float f = i.vend.z;
        float3 ac = normalize(i.vnormal);
        float3 zf = float3(0.0, 0.0, ev.z < 0.0 ? -1.0 : 1.0);
        float zac = dot(zf, ac);
        float x = t * (f + r);
        float u = 0.0;
        n = zf;
        if (x > f + r * zac) u = clamp((x - f) / r, -1.0, 1.0);
        else if (x < r * zac - f) u = clamp((x + f) / r, -1.0, 1.0);
        if (u != 0.0) n = normalize(ev * sqrt(max(1.0 - u * u, 0.0)) + ac * u);
    }
    // A far bead is a pixel or two across, and its round shading beats
    // against the pixel grid. Under 5 pixels the gloss fades.
    float flat_k = 1.0 - smoothstep(2.0, 5.0, px);
    // A focus (params.z != 0) draws in two passes: the beads in focus,
    // solid (params.w < 2), then the other beads as faint ghosts (params.w
    // = 2, blended, no depth write).
    bool focus = params.z > 0.5 || params.z < -0.5;
    if (focus && params.w > 1.5) {
        if (i.vfocus > 0.5) discard;
        float rim = 1.0 - abs(dot(n, v));
        return float4(0.55, 0.58, 0.62, 0.03 + 0.09 * rim);
    }
    if (focus && i.vfocus < 0.5) discard;
    float3 l = normalize(light.xyz);
    float3 base = toLinear(i.vcolor);
    // A selection (params.x < params.y): the selected path in a strong
    // yellow. A print view (params.w = 4): params.x to params.y are the
    // beads of the top layer.
    bool lit = params.w > 3.5;
    if (!lit && params.y > params.x && i.vhigh > 0.5) {
        base = toLinear(float3(1.0, 0.78, 0.05));
    }
    // More light from the sky (up) than from the ground.
    float ambient = lerp(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    float3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18 * (1.0 - flat_k);
    float3 c = base * (ambient + 0.85 * diffuse) + float3(spec, spec, spec);
    // A print view: the top layer is lit, and the layers under it are
    // darker.
    if (lit) c = i.vhigh > 0.5 ? c * 1.12 + base * 0.10 : c * 0.70;
    // The toolhead of a replay (params.w = 3): lit and see-through, with a
    // brighter rim.
    if (params.w > 2.5 && params.w < 3.5) {
        float rim = 1.0 - abs(dot(n, v));
        return float4(toSrgb(c + 0.25 * rim * rim), 0.38 + 0.3 * rim);
    }
    // A plate whose slice is old, or that cannot slice (light.w): the
    // colors fade to the background.
    return float4(lerp(toSrgb(c), float3(0.965, 0.969, 0.973), light.w), 1.0);
}
