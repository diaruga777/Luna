//
//  RabbitHoleTransition.metal
//  ClipContentRendering
//
//  A self-contained, GPU two-phase transition between two screen snapshots
//  (A = the existing view, B = the final view) for the RabbitHole reader:
//
//    Phase 1 (progress 0 → phaseSplit): the existing view dissolves into a
//      PIXELATED version of the final view, one mosaic cell at a time, in random
//      order — each cell crosses from raw A straight to the pixelated B on its own
//      staggered schedule.
//    Phase 2 (progress phaseSplit → 1): that fully-pixelated final image sharpens
//      back to the un-pixelated final view (a global pixelated B → raw B mix).
//
//  Driven by one global `progress`. Pure GPU; the only inputs are the two snapshot
//  textures + a small uniform struct. Deliberately separate from the shipping
//  HalftoneEffect shader so that effect can't regress.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `RHTransitionUniforms` in Swift — keep field order/packing identical.
struct RHTransitionUniforms {
    float2 resolution;   // drawable size in px
    float  cellSize;     // px size of one mosaic "pixel"
    float  progress;     // 0..1 global
    float  phaseSplit;   // progress value where phase 1 ends / phase 2 begins
    float  stagger;      // phase-1 per-cell start spread (0 = all together, 1 = fully sequential)
    float  flipV;        // 0/1 sample with vertical flip (texture origin fix)
    float  monochrome;   // 0 colour, 1 greyscale
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

    float2 uv = in.uv;
    float2 sampleUV = float2(uv.x, U.flipV > 0.5 ? 1.0 - uv.y : uv.y);

    // The mosaic cell this fragment belongs to, sampled at its centre (flat block).
    float2 fragPx = uv * U.resolution;
    float pitch = max(U.cellSize, 1.0);
    float2 cell = floor(fragPx / pitch);
    float2 cellCenter = (cell * pitch + pitch * 0.5) / U.resolution;
    float2 cellSampleUV = float2(cellCenter.x, U.flipV > 0.5 ? 1.0 - cellCenter.y : cellCenter.y);

    float split = clamp(U.phaseSplit, 0.01, 0.99);

    float4 c;
    if (U.progress < split) {
        // Phase 1: per-cell staggered crossfade from the raw existing view to the
        // pixelated final view (one random "pixel" at a time).
        float4 rawA = texA.sample(s, sampleUV);
        float4 pixB = texB.sample(s, cellSampleUV);
        if (U.monochrome > 0.5) { rawA.rgb = rh_mono(rawA.rgb); pixB.rgb = rh_mono(pixB.rgb); }

        float p1 = U.progress / split;                    // 0..1 within phase 1
        float window = clamp(1.0 - U.stagger, 0.001, 1.0); // each cell animates over this fraction
        float start = rh_hash(cell) * (1.0 - window);      // random per-cell start offset
        float local = clamp((p1 - start) / window, 0.0, 1.0);
        c = mix(rawA, pixB, local);
    } else {
        // Phase 2: globally sharpen the pixelated final image into the real final view.
        float4 pixB = texB.sample(s, cellSampleUV);
        float4 rawB = texB.sample(s, sampleUV);
        if (U.monochrome > 0.5) { pixB.rgb = rh_mono(pixB.rgb); rawB.rgb = rh_mono(rawB.rgb); }

        float p2 = (U.progress - split) / (1.0 - split);  // 0..1 within phase 2
        c = mix(pixB, rawB, p2);
    }
    c.a = 1.0;
    return c;
}
