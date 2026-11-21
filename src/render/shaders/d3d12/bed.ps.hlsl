// The HLSL form of shaders/bed.frag: a soft gray with a little light, the
// texture over it at part strength. The parts of the model over the plate
// and the whole bed from under it are see-through.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 color;
    float4 light;
    float4 params;
};

Texture2D tex : register(t0);
SamplerState smp : register(s0);

struct PsIn {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    float2 vuv : TEXCOORD1;
    float vz : TEXCOORD2;
};

float4 main(PsIn i) : SV_Target {
    float3 n = normalize(i.vnormal);
    // Both sides of a face: the files do not agree on the winding.
    float lit = 0.7 + 0.3 * abs(dot(n, normalize(light.xyz)));
    float3 col = color.rgb * lit;
    if (params.x > 0.5 && i.vuv.x > -0.5) {
        // The texture has one mip level.
        float4 t = tex.SampleLevel(smp, i.vuv, 0.0);
        col = lerp(col, t.rgb * lit, t.a * 0.7);
    }
    float a = (i.vz > params.y || params.z > 0.5) ? 0.3 : 1.0;
    return float4(col, a);
}
