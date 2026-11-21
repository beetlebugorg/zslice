// The HLSL form of shaders/decal.frag: the decals of the labels, a flat
// color with no light. The color comes in the normal, the alpha in uv.x.
// SPDX-License-Identifier: AGPL-3.0-or-later

struct PsIn {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    float2 vuv : TEXCOORD1;
    float vz : TEXCOORD2;
};

float4 main(PsIn i) : SV_Target {
    return float4(i.vnormal, i.vuv.x);
}
