// The HLSL form of shaders/paint.vert: the mesh of the Paint tool. A vertex
// is a bed vertex; its uv has two integers: the color 0xRRGGBB, and the
// flags (1: lit, 2: hidden).
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 color;
    float4 light;
    float4 params;
};

struct VsIn {
    float3 p : TEXCOORD0;
    float3 normal : TEXCOORD1;
    uint2 info : TEXCOORD2;
};

struct VsOut {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    nointerpolation uint vrgb : TEXCOORD1;
    nointerpolation uint vflags : TEXCOORD2;
};

VsOut main(VsIn i) {
    VsOut o;
    o.position = mul(mvp, float4(i.p, 1.0));
    o.position.y = -o.position.y;
    o.vnormal = i.normal;
    o.vrgb = i.info.x;
    o.vflags = i.info.y;
    return o;
}
