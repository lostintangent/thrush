#include <metal_stdlib>
using namespace metal;

// Each rectangle is local to its row. Moving a row only changes the vertex uniform.
struct Quad {
    float4 rect;
    float4 uv;
    uint4 paint;  // color token, material (solid / mask / RGBA), dim, unused
};

struct Raster {
    float4 position [[position]];
    float2 uv;
    float4 ink;
    uint material [[flat]];
};

vertex Raster terminalVertex(uint corner [[vertex_id]], uint instance [[instance_id]],
                             const device Quad *quads [[buffer(0)]],
                             constant float4 &viewport [[buffer(1)]],
                             constant float4 *palette [[buffer(2)]]) {
    float2 unit = float2(corner & 1, corner >> 1);
    Quad q = quads[instance];
    float2 pixel = q.rect.xy + q.rect.zw * unit + float2(0, viewport.z);
    Raster out;
    out.position = float4(pixel / viewport.xy * float2(2, -2) + float2(-1, 1), 0, 1);
    out.uv = q.uv.xy + q.uv.zw * unit;
    uint c = q.paint.x;
    out.ink = (c & 0x80000000) ? float4((c >> 16) & 255, (c >> 8) & 255, c & 255, 255) / 255.0 : palette[c];
    out.ink.a *= q.paint.z ? 0.65 : 1.0;
    out.material = q.paint.y;
    return out;
}

fragment float4 terminalFragment(Raster in [[stage_in]], texture2d<float> atlas [[texture(0)]]) {
    if (in.material == 0) return float4(in.ink.rgb * in.ink.a, in.ink.a);
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::nearest);
    float4 glyph = atlas.sample(s, in.uv);
    if (in.material == 2) return glyph * in.ink.a;
    float coverage = glyph.a * in.ink.a;
    return float4(in.ink.rgb * coverage, coverage);
}
