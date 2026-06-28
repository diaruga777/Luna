//
//  RabbitHoleTransition.metal
//  ClipContentRendering
//
//  A self-contained, GPU two-wavefront transition between two screen snapshots
//  (A = the existing view, B = the final view). Used everywhere the app plays a
//  "pixel wipe": the RabbitHole reader's dive / pop / overscroll AND the global
//  halftone transitions (nav push/pop, modal present/dismiss, in-place crossfades,
//  table batch updates).
//
//  Two overlapping wavefronts, both driven by one global `progress` (0 = A, 1 = B):
//    Wave 1 turns each cell from the raw existing view (A) into a PIXELATED dot of
//      the final view (B) — a rounded-rect dot of the cell-centre colour over a
//      flat gap colour.
//    Wave 2 turns that pixelated dot into the real final view (B).
//  Each cell has its own wave-1 arrival time t1 and wave-2 arrival time t2 = t1 + lag,
//  so wave 2 can already be sweeping cells that wave 1 finished while wave 1 is still
//  advancing — i.e. the second wave starts while the first is only partway through.
//  The arrival order is contextual: random (a hash) or directional (cell position
//  along an axis, e.g. right-to-left for a nav push).
//
//  Pure GPU: one draw call per frame, all per-fragment. Inputs are the two snapshot
//  textures + a small uniform struct. Deliberately separate from the shipping
//  HalftoneEffect shader so that effect can't regress.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `Uniforms` in RabbitHoleTransitionView.swift — keep field order/packing
// identical. `gapColor` (float4) is first so its 16-byte alignment can't introduce
// hidden padding between a leading float2 and it.
struct RHTransitionUniforms {
    float4 gapColor;      // pixelated-state gap fill (opaque, a = 1)
    float2 resolution;    // drawable size in px
    float  cellSize;      // px pitch of one mosaic cell (pixelSize_pt * scale)
    float  cornerRadius;  // px dot corner radius (cornerRadius_pt * scale)
    float  spacing;       // px total gap between dots (spacing_pt * scale)
    float  progress;      // 0..1 global timeline
    float  lag;           // 0..1 normalized delay between wave 1 and wave 2 arrival
    float  win1;          // 0..1 wave-1 per-cell crossfade window width
    float  win2;          // 0..1 wave-2 per-cell crossfade window width
    float  direction;     // 0 random, 1 L→R, 2 R→L, 3 T→B, 4 B→T
    float  flipV;         // 0/1 sample with vertical flip (texture origin fix)
    float  monochrome;    // 0 colour, 1 greyscale
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

    // Exact-endpoint hard snaps, independent of all per-cell math: protects against
    // float rounding and jitter pushing an arrival time slightly out of [0, 1].
    if (U.progress <= 0.0) {
        float4 a = texA.sample(s, sampleUV);
        if (U.monochrome > 0.5) a.rgb = rh_mono(a.rgb);
        a.a = 1.0; return a;
    }
    if (U.progress >= 1.0) {
        float4 b = texB.sample(s, sampleUV);
        if (U.monochrome > 0.5) b.rgb = rh_mono(b.rgb);
        b.a = 1.0; return b;
    }

    // The mosaic cell this fragment belongs to, sampled at its centre (flat block).
    float2 fragPx = uv * U.resolution;
    float  pitch  = max(U.cellSize, 1.0);
    float2 cell   = floor(fragPx / pitch);
    float2 cellCenter = (cell * pitch + pitch * 0.5) / U.resolution;
    float2 cellSampleUV = float2(cellCenter.x, U.flipV > 0.5 ? 1.0 - cellCenter.y : cellCenter.y);

    float4 rawA = texA.sample(s, sampleUV);
    float4 rawB = texB.sample(s, sampleUV);
    float4 pixB = texB.sample(s, cellSampleUV);   // cell-centre colour of the final view
    if (U.monochrome > 0.5) {
        rawA.rgb = rh_mono(rawA.rgb);
        rawB.rgb = rh_mono(rawB.rgb);
        pixB.rgb = rh_mono(pixB.rgb);
    }

    // Rounded-rect dot mask within the cell (all in px). The dot fills the cell minus
    // `spacing` total (spacing/2 gap on each side); the rest is the gap colour.
    float2 inCell = fragPx - cell * pitch;
    float2 c0     = float2(pitch * 0.5);
    float  halfExtent = max((pitch - U.spacing) * 0.5, 0.0);
    float  cr     = clamp(U.cornerRadius, 0.0, halfExtent);
    float2 d      = abs(inCell - c0) - (halfExtent - cr);
    float  sdf    = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0) - cr;
    float  aa     = max(fwidth(sdf), 1e-4);
    float  dotMask = 1.0 - smoothstep(-aa, aa, sdf);     // 1 inside dot, 0 in gap

    float3 pixRGB = mix(U.gapColor.rgb, pixB.rgb, dotMask);
    float4 pix    = float4(pixRGB, 1.0);

    // Per-cell arrival ranks per direction (0 = arrives first). Directional modes use
    // the same rank for both waves (one travelling front) with a little hash jitter so
    // the front is soft, not a razor line; random mode uses two different hashes so the
    // sharpen reveals in a different order than the pixelation.
    float2 cellsXY  = max(U.resolution / pitch, float2(1.0));
    float2 cellNorm = (cell + 0.5) / cellsXY;
    float  h        = rh_hash(cell);
    float  jitter   = 0.06;

    float r1, r2;
    int dir = int(U.direction + 0.5);
    if (dir == 1)      { r1 = cellNorm.x;        r2 = r1; }       // L→R
    else if (dir == 2) { r1 = 1.0 - cellNorm.x;  r2 = r1; }       // R→L
    else if (dir == 3) { r1 = cellNorm.y;        r2 = r1; }       // T→B
    else if (dir == 4) { r1 = 1.0 - cellNorm.y;  r2 = r1; }       // B→T
    else               { r1 = h; r2 = rh_hash(cell + 19.7); }     // random

    if (dir != 0) {
        r1 = clamp(r1 + (h - 0.5) * 2.0 * jitter, 0.0, 1.0);
        r2 = r1;
    }

    // Arrival-time timeline, normalized so endpoints stay exact: the slowest cell's
    // wave 2 still finishes by progress = 1, and no wave starts before progress > 0.
    float win1 = clamp(U.win1, 0.001, 1.0);
    float win2 = clamp(U.win2, 0.001, 1.0);
    float spanEnd = max(1.0 - win2, 0.001);
    float lag = clamp(U.lag, 0.0, spanEnd - 0.001);

    float t1 = r1 * (spanEnd - lag);            // wave-1 start
    float t2 = r2 * (spanEnd - lag) + lag;      // wave-2 start (== t1 + lag for directional)

    float local1 = clamp((U.progress - t1) / win1, 0.0, 1.0);
    float local2 = clamp((U.progress - t2) / win2, 0.0, 1.0);

    // Composite: A → pixelated dot → B.
    float4 c = mix(rawA, pix, local1);
    c = mix(c, rawB, local2);
    c.a = 1.0;
    return c;
}
