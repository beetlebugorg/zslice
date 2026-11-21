// The HLSL form of shaders/grid.frag.
// SPDX-License-Identifier: AGPL-3.0-or-later

cbuffer Push : register(b0) {
    float4x4 mvp;
    float4 color;
    float4 eye;
    float4 params;
};

float4 main() : SV_Target {
    return float4(color.rgb, 1.0);
}
