static float2 positions[3] = float2[](
    float2(-0.5, -0.5),
    float2(0.5, -0.5),
    float2(0.0, 0.5),
);

[[vk_push_constant]]
uniform float3 colors[3];

struct VertexOutput {
    float4 sv_position : SV_Position;
    float3 color;
};

[shader("vertex")]
VertexOutput vertexMain(uint vid : SV_VertexID) {
    VertexOutput output;
    output.sv_position = float4(positions[vid], 0.0, 1.0);
    output.color = colors[vid];
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput vout) : SV_Target
{
    return float4(vout.color, 1.0);
}