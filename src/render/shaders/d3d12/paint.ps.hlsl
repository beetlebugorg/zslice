// The HLSL form of shaders/paint.frag: the color of the filament of each
// triangle. A lit triangle mixes with blue. A hidden triangle draws nothing.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 color;
    float4 light;
    float4 params;
};

struct PsIn {
    float4 position : SV_Position;
    float3 vnormal : TEXCOORD0;
    nointerpolation uint vrgb : TEXCOORD1;
    nointerpolation uint vflags : TEXCOORD2;
};

float4 main(PsIn i) : SV_Target {
    if ((i.vflags & 2u) != 0u) discard;
    float3 c = float3(float((i.vrgb >> 16) & 255u), float((i.vrgb >> 8) & 255u), float(i.vrgb & 255u)) / 255.0;
    float3 n = normalize(i.vnormal);
    float lit = 0.45 + 0.55 * max(dot(n, normalize(light.xyz)), 0.0) + 0.15 * abs(n.z);
    float3 col = c * min(lit, 1.0);
    if ((i.vflags & 1u) != 0u) col = lerp(col, float3(0.2, 0.55, 1.0), 0.45);
    return float4(col, 1.0);
}
