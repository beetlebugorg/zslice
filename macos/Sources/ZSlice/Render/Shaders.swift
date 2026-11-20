// The Metal shaders of the 3D view: ports of src/render/shaders/*.vert and
// *.frag (the Vulkan backend) to the Metal Shading Language. The web app
// has the same ports in GLSL ES (web/app/gl.js). Change them together.
//
// The core makes its matrices for the clip space of Vulkan: y goes down,
// and depth goes from 0 to 1. Metal has the same depth range, but y goes
// up, so each vertex shader turns y over.
//
// The app compiles the source when it starts (MTLDevice.makeLibrary), so
// the build needs no Metal tools.
//
// Reference: the Metal Shading Language Specification of Apple (see
// REFERENCES.md).
//
// SPDX-License-Identifier: AGPL-3.0-or-later

let shaderSource = """
#include <metal_stdlib>
using namespace metal;

// The push constants of the core (zs_web_push): a matrix and three vectors.
struct Push {
    float4x4 mvp;
    float4 vec;    // beads: the direction to the light; grid and bed: the color
    float4 eye;    // beads: the camera, w: the top z of the focus; bed: the light
    float4 params;
};

// The values that the Vulkan backend does not have. hoff: added to the
// instance index for the highlight test (1e9: no highlight). fade: how much
// the colors go to the background.
struct Extra {
    float hoff;
    float fade;
    float3 background;
};

// One bead (zs_web_instance): the two end points, the top z, the layer
// height, the bead width, and the color (alpha: the feature).
struct Instance {
    float4 seg;
    packed_float3 zhw;
    uchar4 color;
};

struct BoxOut {
    float4 position [[position]];
    float3 color;
    float3 normal;
    float3 pos;
    float high;
    float focus;
};

constant float3 feature_rgb[14] = {
    float3(0.851, 0.282, 0.059), float3(0.961, 0.624, 0.000),
    float3(0.110, 0.494, 0.839), float3(0.169, 0.541, 0.243),
    float3(0.682, 0.243, 0.788), float3(0.553, 0.431, 0.388),
    float3(0.678, 0.710, 0.741), float3(0.286, 0.314, 0.341),
    float3(0.047, 0.651, 0.682), float3(0.510, 0.788, 0.118),
    float3(0.400, 0.800, 0.949),
    float3(0.878, 0.102, 0.149), float3(0.200, 0.451, 0.949),
    float3(0.949, 0.251, 0.749)};

static float4 toMetal(float4 p) {
    p.y = -p.y;
    return p;
}

// One bead of plastic for each toolpath segment (instanced). The template
// vertex tv: x: the end (0 at a, 1 at b), y: the direction in the plan
// view, z: the profile angle, w: 0 for the side, 1 for the center of the
// top face, -1 for the center of the bottom face.
vertex BoxOut box_vertex(uint vid [[vertex_id]],
                         uint iid [[instance_id]],
                         const device float4 *mesh [[buffer(0)]],
                         const device Instance *inst [[buffer(1)]],
                         constant Push &pc [[buffer(2)]],
                         constant Extra &ex [[buffer(3)]]) {
    float4 tv = mesh[vid];
    Instance in = inst[iid];
    float4 color = float4(in.color) / 255.0;
    float3 zhw = float3(in.zhw);
    float2 a = in.seg.xy;
    float2 b = in.seg.zw;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 0.0 ? d / len : float2(1.0, 0.0);
    float2 side = float2(-dir.y, dir.x);
    float h = zhw.y;
    float w = zhw.z;
    float2 c = mix(a, b, tv.x);
    // The bead profile: a flat top and bottom, and round sides of radius
    // h / 2. A bead narrower than h is a round thread of diameter w.
    float r = min(h, w) * 0.5;
    float core = max(0.5 * w - r, 0.0);
    float zmid = zhw.x - 0.5 * h;
    float3 pos;
    float3 n;
    uint feature = uint(in.color.a);
    if (tv.w > 0.5) {
        pos = float3(c, zmid + r);
        n = float3(0.0, 0.0, 1.0);
    } else if (tv.w < -0.5) {
        pos = float3(c, zmid - r);
        n = float3(0.0, 0.0, -1.0);
    } else {
        float2 np = dir * cos(tv.y) + side * sin(tv.y);
        // A skin or interface bead is pressed square, with small round
        // corners, against its neighbor. An ironing bead (4, and 9 on a
        // slope) is a flat sheet: the core makes it wide and thin.
        if (feature == 2u || feature == 7u || feature == 4u || feature == 9u) {
            float hw = 0.52 * w;
            float hh = 0.5 * h;
            float rr = 0.15 * min(h, w);
            float sp = sin(tv.z);
            float cp = cos(tv.z);
            float x = (hw - rr) + rr * cp;
            float z = sign(sp) * (hh - rr) + rr * sp;
            pos = float3(c + np * x, zmid + z);
            n = normalize(float3(np * cp, sp));
        } else {
            float out_r = core + r * cos(tv.z);
            pos = float3(c + np * out_r, zmid + r * sin(tv.z));
            n = normalize(float3(np * cos(tv.z), sin(tv.z)));
        }
    }
    BoxOut o;
    o.color = color.rgb;
    o.normal = n;
    o.pos = pos;
    float idx = float(iid) + ex.hoff;
    o.high = (idx >= pc.params.x && idx < pc.params.y) ? 1.0 : 0.0;
    // params.z < 0: isolate the selection. Otherwise a bit for each
    // feature in focus (0: no focus).
    bool isolate = pc.params.z < -0.5;
    uint mask = isolate ? 0u : uint(pc.params.z + 0.5);
    bool in_mask = ((mask >> feature) & 1u) != 0u;
    o.focus = (mask == 0u || (in_mask && zhw.x <= pc.eye.w + 1e-4)) ? 1.0 : 0.0;
    if (isolate) o.focus = o.high;
    if (mask != 0u && o.focus > 0.5 && pc.params.w < 0.5) o.color = feature_rgb[min(feature, 13u)];
    // Code 14 and up: overlays, always solid. Codes 12 and 13: the travel
    // and retraction marks, only in a focus on them.
    if (feature >= 14u) {
        o.focus = 1.0;
        o.high = -1.0;
    } else if (feature >= 12u && !in_mask) {
        o.position = float4(0.0);
        return o;
    }
    o.position = toMetal(pc.mvp * float4(pos, 1.0));
    return o;
}

static float3 toLinear(float3 c) { return pow(c, float3(2.2)); }
static float3 toSrgb(float3 c) { return pow(clamp(c, 0.0, 1.0), float3(1.0 / 2.2)); }

// Light for a bead of plastic: a sky and ground ambient term, a diffuse
// term, and a soft specular term. The colors come in and go out as sRGB
// values (the drawable format is UNORM).
static float4 shade(BoxOut in, constant Push &pc, constant Extra &ex) {
    float3 n = normalize(in.normal);
    float3 l = normalize(pc.vec.xyz);
    float3 v = normalize(pc.eye.xyz - in.pos);
    float3 base = toLinear(in.color);
    // The selected path in a strong yellow.
    if (pc.params.y > pc.params.x && in.high > 0.5) base = toLinear(float3(1.0, 0.78, 0.05));
    float ambient = mix(0.18, 0.32, 0.5 + 0.5 * n.z);
    float diffuse = max(dot(n, l), 0.0);
    float3 hv = normalize(l + v);
    float spec = pow(max(dot(n, hv), 0.0), 40.0) * 0.18;
    float3 c = base * (ambient + 0.85 * diffuse) + float3(spec);
    // The toolhead of a replay (params.w = 3): lit and see-through.
    if (pc.params.w > 2.5) {
        float rim = 1.0 - abs(dot(n, v));
        return float4(toSrgb(c + float3(0.25 * rim * rim)), 0.38 + 0.3 * rim);
    }
    return float4(mix(toSrgb(c), ex.background, ex.fade), 1.0);
}

// The plain beads: no discard, so the GPU tests the depth before the
// fragment runs (a discard turns the early test off, which costs much
// when the view is close to many beads).
fragment float4 box_fragment(BoxOut in [[stage_in]],
                             constant Push &pc [[buffer(0)]],
                             constant Extra &ex [[buffer(1)]]) {
    return shade(in, pc, ex);
}

// The beads with a focus, and the see-through passes. A focus draws in
// two passes: the beads in focus (params.w < 2), then the other beads as
// faint ghosts (params.w = 2).
fragment float4 box_fragment_focus(BoxOut in [[stage_in]],
                                   constant Push &pc [[buffer(0)]],
                                   constant Extra &ex [[buffer(1)]]) {
    bool focus = pc.params.z > 0.5 || pc.params.z < -0.5;
    if (focus && pc.params.w > 1.5 && pc.params.w < 2.5) {
        if (in.focus > 0.5) discard_fragment();
        float rim = 1.0 - abs(dot(normalize(in.normal), normalize(pc.eye.xyz - in.pos)));
        return float4(float3(0.55, 0.58, 0.62), 0.03 + 0.09 * rim);
    }
    if (focus && in.focus < 0.5) discard_fragment();
    return shade(in, pc, ex);
}

// The bed outline and the grid lines.
vertex float4 grid_vertex(uint vid [[vertex_id]],
                          const device packed_float3 *points [[buffer(0)]],
                          constant Push &pc [[buffer(1)]]) {
    return toMetal(pc.mvp * float4(float3(points[vid]), 1.0));
}

fragment float4 grid_fragment(constant float4 &color [[buffer(0)]]) {
    return float4(color.rgb, 1.0);
}

// The bed model of the printer (src/bed.zig): position, normal, and uv.
struct BedVertex {
    packed_float3 pos;
    packed_float3 normal;
    packed_float2 uv;
};

struct BedOut {
    float4 position [[position]];
    float3 normal;
    float2 uv;
    float z;
};

vertex BedOut bed_vertex(uint vid [[vertex_id]],
                         const device BedVertex *verts [[buffer(0)]],
                         constant float4x4 &mvp [[buffer(1)]]) {
    BedVertex in = verts[vid];
    BedOut o;
    o.position = toMetal(mvp * float4(float3(in.pos), 1.0));
    o.normal = float3(in.normal);
    o.uv = float2(in.uv);
    o.z = in.pos[2];
    return o;
}

// A soft gray with a little light, and the texture over it at part
// strength. The parts over the plate, and the whole bed from under it, are
// see-through. pc.vec: the color, pc.eye: the light, pc.params: x 1 with a
// texture, y the z over which the bed is see-through, z 1 from under.
fragment float4 bed_fragment(BedOut in [[stage_in]],
                             constant Push &pc [[buffer(0)]],
                             texture2d<float> tex [[texture(0)]],
                             sampler smp [[sampler(0)]]) {
    float3 n = normalize(in.normal);
    float lit = 0.7 + 0.3 * abs(dot(n, normalize(pc.eye.xyz)));
    float3 col = pc.vec.rgb * lit;
    if (pc.params.x > 0.5 && in.uv.x > -0.5) {
        float4 t = tex.sample(smp, in.uv);
        col = mix(col, t.rgb * lit, t.a * 0.7);
    }
    float a = (in.z > pc.params.y || pc.params.z > 0.5) ? 0.3 : 1.0;
    return float4(col, a);
}
// ---- the 2D view of one layer (web/app/gl.js, lineVert and flatVert) ----
//
// A point (x, y) in mm goes to clip space as (x, y) * xf.xy + xf.zw: y goes
// up, as on the bed, and as in the clip space of Metal.

struct Line2D {
    float4 xf;     // the transform from mm to clip space
    float3 solid;  // kind 1: the color
    float px;      // half a pixel in mm: the smallest half width
    float grow;    // the width times this
    float kind;    // 0: the feature colors; 1: one color; 2: a mark
    float mask;    // the focus bits
    float dim;     // 1: all beads faint
};

struct LineOut {
    float4 position [[position]];
    float2 local;
    float len;
    float r;
    float3 color [[flat]];
};

constant float3 bed2d = float3(0.906, 0.914, 0.925);

// A stroke with round ends for each bead (instanced): the quad goes from
// a - r to b + r along the bead, and r to each side. The fragment shader
// cuts the round ends.
vertex LineOut line_vertex(uint vid [[vertex_id]],
                           uint iid [[instance_id]],
                           const device Instance *inst [[buffer(1)]],
                           constant Line2D &u [[buffer(2)]]) {
    Instance in = inst[iid];
    uint feature = uint(in.color.a);
    uint m = uint(u.mask + 0.5);
    float3 zhw = float3(in.zhw);
    float2 a = in.seg.xy;
    float2 b = in.seg.zw;
    float2 d = b - a;
    float len = length(d);
    float2 dir = len > 0.0 ? d / len : float2(1.0, 0.0);
    float2 side = float2(-dir.y, dir.x);
    float r = max(0.5 * zhw.z * u.grow, u.px);
    // A travel move is a thin line.
    if (u.kind > 1.5 && feature == 12u) r = max(0.18 * zhw.z, u.px);
    float s = (vid & 1u) == 0u ? -r : len + r;
    float t = vid < 2u ? -r : r;
    float2 p = a + dir * s + side * t;
    LineOut o;
    o.local = float2(s, t);
    o.len = len;
    o.r = r;
    o.position = float4(p * u.xf.xy + u.xf.zw, 0.0, 1.0);
    if (u.kind > 1.5) {
        // A mark shows only in a focus on it.
        bool on = feature < 14u && ((m >> feature) & 1u) != 0u;
        o.color = feature_rgb[min(feature, 13u)];
        if (!on) o.position = float4(2.0, 2.0, 2.0, 1.0);
        return o;
    }
    if (u.kind > 0.5) {
        o.color = u.solid;
    } else {
        float3 c = feature_rgb[min(feature, 13u)];
        bool focus = m == 0u || ((m >> feature) & 1u) != 0u;
        o.color = (u.dim > 0.5 || !focus) ? mix(bed2d, c, 0.12) : c;
    }
    return o;
}

fragment float4 line_fragment(LineOut in [[stage_in]]) {
    // Outside the round ends: no pixel.
    float s = in.local.x < 0.0 ? in.local.x : (in.local.x > in.len ? in.local.x - in.len : 0.0);
    if (s * s + in.local.y * in.local.y > in.r * in.r) discard_fragment();
    return float4(in.color, 1.0);
}

struct Flat2D {
    float4 xf;
    float4 color;
    float2 size;   // scales the points (the bed quad is 0 to 1)
    uint stride;   // the floats of a point: 2, or 3 for the grid of the 3D view
};

// The bed, the grid, and the outline: points in mm, in one color.
vertex float4 flat_vertex(uint vid [[vertex_id]],
                          const device float *pts [[buffer(0)]],
                          constant Flat2D &u [[buffer(1)]]) {
    float2 p = float2(pts[vid * u.stride], pts[vid * u.stride + 1]);
    return float4(p * u.size * u.xf.xy + u.xf.zw, 0.0, 1.0);
}

fragment float4 flat_fragment(constant Flat2D &u [[buffer(0)]]) {
    return u.color;
}

// The Paint tool (Core/PaintTool.swift, web/app/gl.js paintVert and
// paintFrag): the mesh of a part, each triangle in the color of its
// filament. posnorm: the position and the normal of each vertex. state: 0
// the filament of the part, k color k of the palette, + 128 for the region
// under the pointer, 255 a triangle with pieces (they draw from their own
// buffer).
struct PaintOut {
    float4 position [[position]];
    float3 normal;
    uint state [[flat]];
};

vertex PaintOut paint_vertex(uint vid [[vertex_id]],
                             const device packed_float3 *posnorm [[buffer(0)]],
                             constant float4x4 &mvp [[buffer(1)]],
                             const device float *states [[buffer(2)]]) {
    PaintOut o;
    o.position = toMetal(mvp * float4(float3(posnorm[2 * vid]), 1.0));
    o.normal = float3(posnorm[2 * vid + 1]);
    o.state = uint(states[vid] + 0.5);
    return o;
}

fragment float4 paint_fragment(PaintOut in [[stage_in]],
                               constant float4 *colors [[buffer(0)]]) {
    if (in.state == 255) discard_fragment();
    uint k = in.state & 127;
    float3 c = colors[min(k, 17u)].rgb;
    float3 n = normalize(in.normal);
    float lit = 0.45 + 0.55 * max(dot(n, normalize(float3(-0.4, -0.6, 0.7))), 0.0) + 0.15 * abs(n.z);
    float3 col = c * min(lit, 1.0);
    if (in.state >= 128) col = mix(col, float3(0.2, 0.55, 1.0), 0.45);
    return float4(col, 1.0);
}
"""
