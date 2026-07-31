struct VertexInput {
    [vk_location(0)]
    float3 position;
    [vk_location(1)]
    float3 color;
};

struct VertexOutput {
    float4 sv_position : SV_Position;
    float3 color;
};

[shader("vertex")]
VertexOutput vertexMain(VertexInput in, uint vid : SV_VertexID) {
    VertexOutput output;
    output.sv_position = float4(in.position, 1.0);
    output.color = in.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput vout) : SV_Target
{
    return float4(vout.color, 1.0);
}