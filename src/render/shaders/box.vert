// One bead of plastic for each toolpath segment (instanced). See
// src/render/view.zig for the template mesh.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

// The template vertex: x: the end (0 at a, 1 at b), y: the direction alpha
// in the plan view (0 along the segment, pi/2 to its left), z: the profile
// angle phi (-pi/2 at the bottom, pi/2 at the top), w: 0 for the side, 1
// for the center of the top face, -1 for the center of the bottom face, 2
// for the ribbon of a far bead (y: -1 to 1 across it).
layout(location = 0) in vec4 tv;
// The instance: the two end points, then the top z, the layer height, and
// the bead width, then the color.
layout(location = 2) in vec4 seg;
layout(location = 3) in vec3 zhw;
layout(location = 4) in vec4 color;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 light;  // xyz: the direction to the light
    vec4 eye;    // xyz: the camera position, w: the top z of the focus
    vec4 params; // x, y: the first and the end instance to highlight,
                 // z: the focus: a bit for each feature, 0 for no focus
} pc;

layout(location = 0) out vec3 vcolor;
layout(location = 1) out vec3 vnormal;
layout(location = 2) out vec3 vpos;
layout(location = 3) out float vhigh;
// 1 for a bead in focus (or no focus), 0 for a bead that fades.
layout(location = 4) out float vfocus;
// xy: the plan normal of the side of the bead, z: the place across the
// cross section (-0.5 to 0.5), w: the radius of a ribbon (0 for the
// meshes). box.frag measures the bead on the screen with z.
layout(location = 5) out vec4 vsec;
// The ribbon: the place along it past each end (-1 at the tip of the
// round end, > 0 between the ends), and the half width of its flat face.
layout(location = 6) out vec3 vend;

// The feature colors (sRGB), as in linux/src/ui/colors.h. In a focus, a
// bead in focus shows its feature color, so it stands out also when the
// filament color is pale.
// After the 10 features: the marks (seam, travel, retraction).
// The colors of the features, then of the marks (seam, travel,
// retraction), as feature_rgb in view.zig.
const vec3 feature_rgb[14] = vec3[14](
    vec3(0.851, 0.282, 0.059), vec3(0.961, 0.624, 0.000),
    vec3(0.110, 0.494, 0.839), vec3(0.169, 0.541, 0.243),
    vec3(0.682, 0.243, 0.788), vec3(0.553, 0.431, 0.388),
    vec3(0.678, 0.710, 0.741), vec3(0.286, 0.314, 0.341),
    vec3(0.047, 0.651, 0.682), vec3(0.510, 0.788, 0.118),
    vec3(0.400, 0.800, 0.949),
    vec3(0.878, 0.102, 0.149), vec3(0.200, 0.451, 0.949),
    vec3(0.949, 0.251, 0.749));

void main() {
    vec2 a = seg.xy;
    vec2 b = seg.zw;
    vec2 d = b - a;
    float len = length(d);
    vec2 dir = len > 0.0 ? d / len : vec2(1.0, 0.0);
    vec2 side = vec2(-dir.y, dir.x);
    float h = zhw.y;
    float w = zhw.z;
    vec2 c = mix(a, b, tv.x);
    // The bead profile: a flat top and bottom, and round sides of radius
    // h / 2. A bead narrower than h is a round thread of diameter w.
    float r = min(h, w) * 0.5;
    float core = max(0.5 * w - r, 0.0);
    float zmid = zhw.x - 0.5 * h;
    vec3 pos;
    vec3 n;
    vend = vec3(0.0);
    if (tv.w > 1.5) {
        // The ribbon of a far bead (mesh level 2): a strip that faces the
        // camera, as wide as the bead looks from there. The normals go
        // from one side of the bead, through the middle, to the other
        // side, so the strip shades as a round bead.
        vec3 d3 = vec3(dir, 0.0);
        vec3 s3 = vec3(side, 0.0);
        vec3 e = pc.eye.xyz - vec3(0.5 * (a + b), zmid);
        e = length(e) > 0.0 ? normalize(e) : vec3(0.0, 0.0, 1.0);
        // al: the bead on the screen. ac: across it, in the cross section.
        vec3 al = d3 - e * dot(d3, e);
        al = length(al) > 1e-4 ? normalize(al) : normalize(cross(e, abs(e.z) < 0.9 ? vec3(0.0, 0.0, 1.0) : vec3(1.0, 0.0, 0.0)));
        vec3 ac = cross(e, al);
        float flat_w = core * abs(dot(ac, s3));
        float hw = flat_w + r;
        float ext = max(length(vec2(0.5 * w * length(al.xy), r * al.z)), 1e-4);
        vec3 end = vec3(tv.x < 0.5 ? a : b, zmid);
        // A radius closer to the eye: about at the front of the bead.
        pos = end + al * ((tv.x < 0.5 ? -1.0 : 1.0) * ext) + ac * (tv.y * hw) + e * r;
        // box.frag makes the normal of each pixel from ac and the place
        // across (vsec.z), and cuts round ends with vend.
        n = ac;
        vsec = vec4(dot(e, s3) < 0.0 ? -side : side, 0.5 * tv.y, max(r, 1e-4));
        float q = (len * dot(d3, al) + ext) / ext;
        vend = vec3(tv.x < 0.5 ? vec2(-1.0, q) : vec2(q, -1.0), flat_w);
    } else if (tv.w > 0.5) {
        pos = vec3(c, zmid + r);
        n = vec3(0.0, 0.0, 1.0);
        vsec = vec4(0.0, 0.0, 0.5, 0.0);
    } else if (tv.w < -0.5) {
        pos = vec3(c, zmid - r);
        n = vec3(0.0, 0.0, -1.0);
        vsec = vec4(0.0, 0.0, -0.5, 0.0);
    } else {
        vec2 np = dir * cos(tv.y) + side * sin(tv.y);
        vsec = vec4(np, tv.z / 3.14159265, 0.0);
        // A skin or interface bead lies against its neighbor: the plastic
        // fills the groove between them, so the bead is pressed square
        // with small round corners (a superellipse), and the surface is
        // continuous. A free bead (a wall, infill) keeps its round sides.
        uint feat = uint(color.a * 255.0 + 0.5);
        if (feat == 2u || feat == 7u || feat == 4u || feat == 9u) {
            // A rounded rectangle: a flat top out to hw - rr, flat sides,
            // and corner arcs of radius rr. The profile angles of the mesh
            // fall on the corner arcs, so the top stays flat. 4 % wider:
            // the beads overlap a little, as the pressed plastic does, so
            // no gap shows between them.
            float hw = 0.52 * w;
            float hh = 0.5 * h;
            float rr = 0.15 * min(h, w);
            float sp = sin(tv.z);
            float cp = cos(tv.z);
            float x = (hw - rr) + rr * cp;
            float z = sign(sp) * (hh - rr) + rr * sp;
            pos = vec3(c + np * x, zmid + z);
            n = normalize(vec3(np * cp, sp));
        } else {
            float out_r = core + r * cos(tv.z);
            pos = vec3(c + np * out_r, zmid + r * sin(tv.z));
            n = normalize(vec3(np * cos(tv.z), sin(tv.z)));
        }
    }
    vcolor = color.rgb;
    vnormal = n;
    vpos = pos;
    float idx = float(gl_InstanceIndex);
    vhigh = (idx >= pc.params.x && idx < pc.params.y) ? 1.0 : 0.0;
    // The alpha byte of the color has the feature of the bead.
    // params.z < 0: isolate the selection: the selected path is solid,
    // and all other beads are ghosts.
    bool isolate = pc.params.z < -0.5;
    uint mask = isolate ? 0u : uint(pc.params.z + 0.5);
    uint feature = uint(color.a * 255.0 + 0.5);
    bool in_mask = ((mask >> feature) & 1u) != 0u;
    vfocus = (mask == 0u || (in_mask && zhw.x <= pc.eye.w + 1e-4)) ? 1.0 : 0.0;
    if (isolate) vfocus = vhigh;
    // params.w = 0: the filament color mode, where all beads have one
    // color, so a bead in focus shows its feature color. In the other
    // modes (params.w = 1) the beads keep the colors of the mode.
    if (mask != 0u && vfocus > 0.5 && pc.params.w < 0.5) vcolor = feature_rgb[min(feature, 13u)];
    // The travel and retraction marks show only in a focus on them: they
    // are not part of the printed part. A mark that does not show goes
    // behind the camera (w = 0 clips it).
    // Code 14 and up: overlays (the frame of a selected part). They
    // are always solid, in their own color. Codes 12 and 13: the travel
    // and retraction marks (code_travel and code_retract in view.zig).
    if (feature >= 14u) {
        vfocus = 1.0;
        vhigh = -1.0;
    } else if (feature >= 12u && !in_mask) {
        gl_Position = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    gl_Position = pc.mvp * vec4(pos, 1.0);
}
