// One box for each toolpath segment (instanced). See src/render/view.zig.
// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

// The unit box: x 0..1 along the segment, y -1..1 across, z -1..0 down.
layout(location = 0) in vec3 corner;
// The face normal in the same frame.
layout(location = 1) in vec3 nrm;
// The instance: the two end points, then the top z, the layer height, and
// the line width, then the color.
layout(location = 2) in vec4 seg;
layout(location = 3) in vec3 zhw;
layout(location = 4) in vec4 color;

layout(push_constant) uniform Push {
    mat4 mvp;
    vec4 light; // xyz: the direction to the light
} pc;

layout(location = 0) out vec3 vcolor;

void main() {
    vec2 a = seg.xy;
    vec2 b = seg.zw;
    vec2 d = b - a;
    float len = length(d);
    vec2 dir = len > 0.0 ? d / len : vec2(1.0, 0.0);
    vec2 side = vec2(-dir.y, dir.x);
    float hw = 0.5 * zhw.z;
    // The box goes a little past each end, so that the boxes of one path
    // meet at the corners.
    float along = mix(-0.5 * hw, len + 0.5 * hw, corner.x);
    vec2 p = a + dir * along + side * corner.y * hw;
    float z = zhw.x + corner.z * zhw.y;
    vec3 n = normalize(vec3(dir * nrm.x + side * nrm.y, nrm.z));
    float lit = 0.35 + 0.65 * max(dot(n, pc.light.xyz), 0.0);
    vcolor = color.rgb * lit;
    gl_Position = pc.mvp * vec4(p, z, 1.0);
}
