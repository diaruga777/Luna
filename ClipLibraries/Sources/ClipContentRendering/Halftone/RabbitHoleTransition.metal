//
//  RabbitHoleTransition.metal
//  ClipContentRendering
//
//  A self-contained, GPU pixel-mosaic transition between two screen snapshots
//  (A = before, B = after) for the RabbitHole reader. Each cell ("pixel") runs an
//  independent 4-stage path on a staggered, per-cell random schedule, so the screen
//  dissolves cell-by-cell in random order:
//
//    raw A  →  pixelated A  →  pixelated B  →  raw B
//
//  Driven by one global `progress` (0 = all raw-A, 1 = all raw-B). A cell with random
//  key r starts at `r * (1 - window)` and animates over `window`, so at any moment some
//  cells are untouched, some mid-pixelation, some finished. Pure GPU; the only inputs
//  are the two snapshot textures + a small uniform struct. Deliberately separate from
//  the shipping HalftoneEffect shader so that effect can't regress.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `RHTransitionUniforms` in Swift — keep field order/packing identical.
struct RHTransitionUniforms {
    float2 resolution;   // drawable size in px
    float  cellSize;     // px size of one mosaic "pixel"
    float  progress;     // 0..1 global
    float  window;       // per-cell animation length as a fraction of total
    float  flipV;        // 0/1 sample with vertical flip (texture origin fix)
    float  monochrome;   // 0 colour, 1 greyscale
    float  _pad;
};

struct RHVSOut {
    float4 position [[position]];
    float2 uv;
};

vertex RHVSOut rh_transition_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    RHVSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);                // top-left origin to match UIKit
    return o;
}

static inline float rh_hash(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}

static inline float3 rh_mono(float3 c) { return float3(dot(c, float3(0.299, 0.587, 0.114))); }

fragment float4 rh_transition_fragment(RHVSOut in [[stage_in]],
                                       texture2d<float, access::sample> texA [[texture(0)]],
                                       texture2d<float, access::sample> texB [[texture(1)]],
                                       constant RHTransitionUniforms& U [[buffer(0)]]) {
    constexpr sampler s(mag_filter::linear, min_filter::linear, address::clamp_to_edge);

    // Vertical flip applied to the sampled v so the texture's origin matches the screen.
    float2 uv = in.uv;
    float2 sampleUV = float2(uv.x, U.flipV > 0.5 ? 1.0 - uv.y : uv.y);

    // The mosaic cell this fragment belongs to, sampled at its centre (flat block).
    float2 fragPx = uv * U.resolution;
    float pitch = max(U.cellSize, 1.0);
    float2 cell = floor(fragPx / pitch);
    float2 cellCenter = (cell * pitch + pitch * 0.5) / U.resolution;
    float2 cellSampleUV = float2(cellCenter.x, U.flipV > 0.5 ? 1.0 - cellCenter.y : cellCenter.y);

    float4 rawA = texA.sample(s, sampleUV);
    float4 rawB = texB.sample(s, sampleUV);
    float4 pixA = texA.sample(s, cellSampleUV);
    float4 pixB = texB.sample(s, cellSampleUV);
    if (U.monochrome > 0.5) {
        rawA.rgb = rh_mono(rawA.rgb); rawB.rgb = rh_mono(rawB.rgb);
        pixA.rgb = rh_mono(pixA.rgb); pixB.rgb = rh_mono(pixB.rgb);
    }

    // Per-cell staggered local progress.
    float r = rh_hash(cell);
    float window = max(U.window, 0.001);
    float start = r * (1.0 - window);
    float local = clamp((U.progress - start) / window, 0.0, 1.0);

    // 4-stage path: raw A → pixelated A → pixelated B → raw B.
    float4 c;
    if (local < 1.0 / 3.0) {
        c = mix(rawA, pixA, local * 3.0);
    } else if (local < 2.0 / 3.0) {
        c = mix(pixA, pixB, (local - 1.0 / 3.0) * 3.0);
    } else {
        c = mix(pixB, rawB, (local - 2.0 / 3.0) * 3.0);
    }
    c.a = 1.0;
    return c;
}
