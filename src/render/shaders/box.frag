// SPDX-License-Identifier: AGPL-3.0-or-later
#version 450

layout(location = 0) in vec3 vcolor;
layout(location = 0) out vec4 frag;

void main() {
    frag = vec4(vcolor, 1.0);
}
