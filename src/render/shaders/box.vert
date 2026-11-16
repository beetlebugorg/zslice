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
    vec4 eye;    // xyz: the camera position
    vec4 params; // x, y: the first and the end instance to highlight
} pc;

layout(location = 0) out vec3 vcolor;
layout(location = 1) out vec3 vnormal;
layout(location = 2) out vec3 vpos;
layout(location = 3) out float vhigh;

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
    gl_Position = pc.mvp * vec4(pos, 1.0);
}
