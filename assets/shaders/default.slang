struct VertexInput {
    [vk_location(0)]
    float3 position;
    [vk_location(1)]
    float3 color;
};

struct PCData {
    float4x4 proj;
    float4x4 view;
    float4x4 model;
}

struct VertexOutput {
    float4 sv_position : SV_Position;
    float3 color;
};

[vk_push_constant]
PCData pcd;

[shader("vertex")]
VertexOutput vertexMain(VertexInput in) {
    VertexOutput output;
    output.sv_position = mul(mul(mul(pcd.proj, pcd.view), pcd.model), float4(in.position, 1.0));
    output.color = in.color;
    return output;
}

[shader("fragment")]
float4 fragmentMain(VertexOutput vout) : SV_Target
{
    return float4(vout.color, 0.5);
}