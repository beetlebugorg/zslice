// One bead of plastic for each toolpath segment (instanced). See
// src/render/view.zig for the template mesh.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

// The template vertex: x: the end (0 at a, 1 at b), y: the direction alpha
// in the plan view (0 along the segment, pi/2 to its left), z: the profile
// angle phi (-pi/2 at the bottom, pi/2 at the top), w: 0 for the side, 1
// for the center of the top face, -1 for the center of the bottom face.
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

// The feature colors (sRGB), as in linux/src/ui/colors.h. In a focus, a
// bead in focus shows its feature color, so it stands out also when the
// filament color is pale.
// After the 8 features: the marks (seam, travel, retraction).
const vec3 feature_rgb[11] = vec3[11](
    vec3(0.851, 0.282, 0.059), vec3(0.961, 0.624, 0.000),
    vec3(0.110, 0.494, 0.839), vec3(0.169, 0.541, 0.243),
    vec3(0.682, 0.243, 0.788), vec3(0.553, 0.431, 0.388),
    vec3(0.678, 0.710, 0.741), vec3(0.286, 0.314, 0.341),
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
    if (tv.w > 0.5) {
        pos = vec3(c, zmid + r);
        n = vec3(0.0, 0.0, 1.0);
    } else if (tv.w < -0.5) {
        pos = vec3(c, zmid - r);
        n = vec3(0.0, 0.0, -1.0);
    } else {
        vec2 np = dir * cos(tv.y) + side * sin(tv.y);
        float out_r = core + r * cos(tv.z);
        pos = vec3(c + np * out_r, zmid + r * sin(tv.z));
        n = normalize(vec3(np * cos(tv.z), sin(tv.z)));
    }
    vcolor = color.rgb;
    vnormal = n;
    vpos = pos;
    float idx = float(gl_InstanceIndex);
    vhigh = (idx >= pc.params.x && idx < pc.params.y) ? 1.0 : 0.0;
    // The alpha byte of the color has the feature of the bead.
    uint mask = uint(pc.params.z + 0.5);
    uint feature = uint(color.a * 255.0 + 0.5);
    bool in_mask = ((mask >> feature) & 1u) != 0u;
    vfocus = (mask == 0u || (in_mask && zhw.x <= pc.eye.w + 1e-4)) ? 1.0 : 0.0;
    if (mask != 0u && vfocus > 0.5) vcolor = feature_rgb[min(feature, 10u)];
    // The travel and retraction marks show only in a focus on them: they
    // are not part of the printed part. A mark that does not show goes
    // behind the camera (w = 0 clips it).
    if (feature >= 9u && !in_mask) {
        gl_Position = vec4(0.0, 0.0, 0.0, 0.0);
        return;
    }
    gl_Position = pc.mvp * vec4(pos, 1.0);
}
