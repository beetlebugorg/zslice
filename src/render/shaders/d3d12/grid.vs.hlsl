// The HLSL form of shaders/grid.vert: the bed outline and grid lines.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 color;
    float4 eye;
    float4 params;
};

float4 main(float3 p : TEXCOORD0) : SV_Position {
    float4 o = mul(mvp, float4(p, 1.0));
    o.y = -o.y;
    return o;
}
