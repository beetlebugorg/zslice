// The HLSL form of shaders/box.vert: one bead of plastic for each toolpath
// segment (instanced). Keep the two files the same.
//
// Two differences from Vulkan. The view makes its matrix for a clip space
// with y down, so this shader negates y. SV_InstanceID starts at 0 for each
// draw, so the backend gives the first instance of the draw in b1.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 light;  // xyz: the direction to the light
    float4 eye;    // xyz: the camera position, w: the top z of the focus
    float4 params; // x, y: the first and the end instance to highlight,
                   // z: the focus: a bit for each feature, 0 for no focus
};

cbuffer DrawData : register(b1) {
    uint first_instance;
};

struct VsIn {
    // The template vertex: x: the end (0 at a, 1 at b), y: the direction
    // alpha in the plan view, z: the profile angle phi, w: 0 for the side,
    // 1 for the center of the top face, -1 for the center of the bottom
    // face, 2 for the ribbon of a far bead (y: -1 to 1 across it).
    float4 tv : TEXCOORD0;
    // The instance: the two end points, then the top z, the layer height,
    // and the bead width, then the color.
    float4 seg : TEXCOORD2;
    float3 zhw : TEXCOORD3;
    float4 color : TEXCOORD4;
    uint instance : SV_InstanceID;
};

struct VsOut {
    float4 position : SV_Position;
    float3 vcolor : TEXCOORD0;
    float3 vnormal : TEXCOORD1;
    float3 vpos : TEXCOORD2;
    float vhigh : TEXCOORD3;
    // 1 for a bead in focus (or no focus), 0 for a bead that fades.
    float vfocus : TEXCOORD4;
    // xy: the plan normal of the side of the bead, z: the place across the
    // cross section (-0.5 to 0.5), w: the radius of a ribbon (0 for the
    // meshes).
    float4 vsec : TEXCOORD5;
    // The ribbon: the place along it past each end, and the half width of
    // its flat face.
    float3 vend : TEXCOORD6;
};

// The colors of the features, then of the marks (seam, travel, retraction),
// as feature_rgb in view.zig.
static const float3 feature_rgb[14] = {
    float3(0.851, 0.282, 0.059), float3(0.961, 0.624, 0.000),
    float3(0.110, 0.494, 0.839), float3(0.169, 0.541, 0.243),
    float3(0.682, 0.243, 0.788), float3(0.553, 0.431, 0.388),
    float3(0.678, 0.710, 0.741), float3(0.286, 0.314, 0.341),
    float3(0.047, 0.651, 0.682), float3(0.510, 0.788, 0.118),
    float3(0.400, 0.800, 0.949),
    float3(0.878, 0.102, 0.149), float3(0.200, 0.451, 0.949),
    float3(0.949, 0.251, 0.749),
};

VsOut main(VsIn i) {
    VsOut o;
    float4 tv = i.tv;
    float2 a = i.seg.xy;
    float2 b = i.seg.zw;
    float2 d = b - a;
    float len = length(d);
    float2 dir = float2(1.0, 0.0);
    if (len > 0.0) dir = d / len;
    float2 side = float2(-dir.y, dir.x);
    float h = i.zhw.y;
    float w = i.zhw.z;
    float2 c = lerp(a, b, tv.x);
    // The bead profile: a flat top and bottom, and round sides of radius
    // h / 2. A bead narrower than h is a round thread of diameter w.
    float r = min(h, w) * 0.5;
    float core = max(0.5 * w - r, 0.0);
    float zmid = i.zhw.x - 0.5 * h;
    float3 p;
    float3 n;
    o.vend = float3(0.0, 0.0, 0.0);
    if (tv.w > 1.5) {
        // The ribbon of a far bead (mesh level 2): a strip that faces the
        // camera, as wide as the bead looks from there.
        float3 d3 = float3(dir, 0.0);
        float3 s3 = float3(side, 0.0);
        float3 e = eye.xyz - float3(0.5 * (a + b), zmid);
        if (length(e) > 0.0) e = normalize(e);
        else e = float3(0.0, 0.0, 1.0);
        // al: the bead on the screen. ac: across it, in the cross section.
        float3 al = d3 - e * dot(d3, e);
        if (length(al) > 1e-4) {
            al = normalize(al);
        } else {
            float3 up = abs(e.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
            al = normalize(cross(e, up));
        }
        float3 ac = cross(e, al);
        float flat_w = core * abs(dot(ac, s3));
        float hw = flat_w + r;
        float ext = max(length(float2(0.5 * w * length(al.xy), r * al.z)), 1e-4);
        float3 tip = float3(tv.x < 0.5 ? a : b, zmid);
        // A radius closer to the eye: about at the front of the bead.
        p = tip + al * ((tv.x < 0.5 ? -1.0 : 1.0) * ext) + ac * (tv.y * hw) + e * r;
        // The pixel shader makes the normal of each pixel from ac and the
        // place across (vsec.z), and cuts round ends with vend.
        n = ac;
        o.vsec = float4(dot(e, s3) < 0.0 ? -side : side, 0.5 * tv.y, max(r, 1e-4));
        float q = (len * dot(d3, al) + ext) / ext;
        o.vend = float3(tv.x < 0.5 ? float2(-1.0, q) : float2(q, -1.0), flat_w);
    } else if (tv.w > 0.5) {
        p = float3(c, zmid + r);
        n = float3(0.0, 0.0, 1.0);
        o.vsec = float4(0.0, 0.0, 0.5, 0.0);
    } else if (tv.w < -0.5) {
        p = float3(c, zmid - r);
        n = float3(0.0, 0.0, -1.0);
        o.vsec = float4(0.0, 0.0, -0.5, 0.0);
    } else {
        float2 np = dir * cos(tv.y) + side * sin(tv.y);
        o.vsec = float4(np, tv.z / 3.14159265, 0.0);
        // A skin or interface bead lies against its neighbor, so the bead
        // is pressed square with small round corners. A free bead (a wall,
        // infill) keeps its round sides.
        uint feat = uint(i.color.a * 255.0 + 0.5);
        if (feat == 2u || feat == 7u || feat == 4u || feat == 9u) {
            float hw = 0.52 * w;
            float hh = 0.5 * h;
            float rr = 0.15 * min(h, w);
            float sp = sin(tv.z);
            float cp = cos(tv.z);
            float x = (hw - rr) + rr * cp;
            float z = sign(sp) * (hh - rr) + rr * sp;
            p = float3(c + np * x, zmid + z);
            n = normalize(float3(np * cp, sp));
        } else {
            float out_r = core + r * cos(tv.z);
            p = float3(c + np * out_r, zmid + r * sin(tv.z));
            n = normalize(float3(np * cos(tv.z), sin(tv.z)));
        }
    }
    o.vcolor = i.color.rgb;
    o.vnormal = n;
    o.vpos = p;
    float idx = float(i.instance + first_instance);
    o.vhigh = (idx >= params.x && idx < params.y) ? 1.0 : 0.0;
    // The alpha byte of the color has the feature of the bead.
    // params.z < 0: isolate the selection: the selected path is solid, and
    // all other beads are ghosts.
    bool isolate = params.z < -0.5;
    uint mask = isolate ? 0u : uint(params.z + 0.5);
    uint feature = uint(i.color.a * 255.0 + 0.5);
    bool in_mask = feature < 32u && ((mask >> feature) & 1u) != 0u;
    o.vfocus = (mask == 0u || (in_mask && i.zhw.x <= eye.w + 1e-4)) ? 1.0 : 0.0;
    if (isolate) o.vfocus = o.vhigh;
    // params.w = 0: the filament color mode, so a bead in focus shows its
    // feature color. In the other modes the beads keep their colors.
    if (mask != 0u && o.vfocus > 0.5 && params.w < 0.5) o.vcolor = feature_rgb[min(feature, 13u)];
    // Code 14 and up: overlays, always solid, in their own color. Codes 12
    // and 13: the travel and retraction marks, which show only in a focus
    // on them. A mark that does not show goes behind the camera.
    if (feature >= 14u) {
        o.vfocus = 1.0;
        o.vhigh = -1.0;
    } else if (feature >= 12u && !in_mask) {
        o.position = float4(0.0, 0.0, 0.0, 0.0);
        return o;
    }
    o.position = mul(mvp, float4(p, 1.0));
    o.position.y = -o.position.y;
    return o;
}
