// The HLSL form of shaders/bed.vert: the bed model, a static mesh under the
// plate. The signs and the decals use this vertex shader too.
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
    float2 uv : TEXCOORD2;
};

struct VsOut {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    float2 vuv : TEXCOORD1;
    float vz : TEXCOORD2;
};

VsOut main(VsIn i) {
    VsOut o;
    o.position = mul(mvp, float4(i.p, 1.0));
    o.position.y = -o.position.y;
    o.vnormal = i.normal;
    o.vuv = i.uv;
    o.vz = i.p.z;
    return o;
}
