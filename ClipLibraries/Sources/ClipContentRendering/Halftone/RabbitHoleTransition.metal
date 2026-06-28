//
//  RabbitHoleTransition.metal
//  ClipContentRendering
//
//  A self-contained halftone *transition* between two screen snapshots (A = before,
//  B = after) for the RabbitHole reader. Deliberately separate from the shipping
//  HalftoneEffect shader so that effect can't regress; it reuses the same dot SDF /
//  hash math by copy.
//
//  A single fragment renders all three phases as a function of two driven values:
//    revealRadius — an expanding/shrinking circle from `revealCenter`; inside it the
//                   screen is halftone dots, outside it the raw snapshot.
//    abMix        — 0 = dots show A, 1 = dots show B; each cell flips A→B when abMix
//                   crosses its own stable random threshold, so dots flip in random
//                   order across the screen.
//  Phase 1 (expand): radius 0→max, abMix 0.   Phase 2 (flip): radius max, abMix 0→1.
//  Phase 3 (collapse): radius max→0, abMix 1.  Reverse is just the values run backward.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `RHTransitionUniforms` in Swift — keep field order/packing identical.
struct RHTransitionUniforms {
    float2 resolution;      // drawable size in px
    float2 revealCenter;    // px, the touch point the wipe radiates from
    float4 gapColor;        // colour of the space between dots
    float  cellSize;        // px grid pitch
    float  dotScale;        // fraction of the cell the dot fills
    float  cornerRadius;    // 0 square … 1 circle
    float  edgeSoftness;    // px AA on the dot edge
    float  revealRadius;    // px radius of the halftone circle
    float  revealEdge;      // px softness of the circle edge
    float  abMix;           // 0 = A dots … 1 = B dots
    float  monochrome;      // 0 colour, 1 greyscale
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

static inline float rh_sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
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

    float2 fragPx = in.uv * U.resolution;
    float pitch = max(U.cellSize, 1.0);
    float2 cellIndex = floor(fragPx / pitch);
    float2 cellCenterPx = cellIndex * pitch + pitch * 0.5;
    float2 cellUV = cellCenterPx / U.resolution;

    // Dot colour: each cell samples A and B at its centre and flips between them when
    // the global abMix crosses this cell's stable random threshold.
    float4 aDot = texA.sample(s, cellUV);
    float4 bDot = texB.sample(s, cellUV);
    if (U.monochrome > 0.5) { aDot.rgb = rh_mono(aDot.rgb); bDot.rgb = rh_mono(bDot.rgb); }
    float thr  = rh_hash(cellIndex);
    float flip = smoothstep(thr - 0.08, thr + 0.08, U.abMix);
    float4 dotColor = mix(aDot, bDot, flip);

    // Dot shape.
    float2 rel = fragPx - cellCenterPx;
    float halfExtent = max(U.cellSize * 0.5 * U.dotScale, 0.0);
    float r = halfExtent * clamp(U.cornerRadius, 0.0, 1.0);
    float sd = rh_sdRoundBox(rel, float2(halfExtent), r);
    float aa = max(U.edgeSoftness, 0.5);
    float dotMask = 1.0 - smoothstep(-aa, aa, sd);
    float4 halftoneLook = mix(U.gapColor, dotColor, dotMask);

    // Raw (un-dotted) snapshot for this pixel — A before the midpoint, B after. The
    // switch happens at abMix 0.5, when the circle is full and only dots are visible,
    // so it never pops.
    float4 rawColor = (U.abMix < 0.5) ? texA.sample(s, in.uv) : texB.sample(s, in.uv);

    // Inside the reveal circle → halftone; outside → raw.
    float distO = length(fragPx - U.revealCenter);
    float halftoneAmount = smoothstep(U.revealRadius + U.revealEdge,
                                      U.revealRadius - U.revealEdge, distO);

    float4 outColor = mix(rawColor, halftoneLook, halftoneAmount);
    outColor.a = 1.0;
    return outColor;
}
