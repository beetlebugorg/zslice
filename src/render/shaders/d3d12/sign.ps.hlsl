// The HLSL form of shaders/sign.frag: the signs of the plates, the image
// that the shell draws, with the alpha of the sign from the normal (x).
// SPDX-License-Identifier: AGPL-3.0-or-later

Texture2D tex : register(t0);
SamplerState smp : register(s0);

struct PsIn {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    float2 vuv : TEXCOORD1;
    float vz : TEXCOORD2;
};

float4 main(PsIn i) : SV_Target {
    float4 t = tex.SampleLevel(smp, i.vuv, 0.0);
    float a = t.a * i.vnormal.x;
    if (a < 0.004) discard;
    return float4(t.rgb, a);
}
