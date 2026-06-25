//
//  HalftoneShaders.metal
//  HalftoneEffect
//
//  Real-time "dot-matrix / halftone" post-process. Each output pixel figures out
//  which grid cell it belongs to, samples the source content at the CENTER of that
//  cell (so the whole cell shows one flat color, like an LED panel), then draws a
//  rounded-rectangle (squircle-ish) "dot" inside the cell. The space between dots
//  is filled with a configurable background color and/or a blurred version of the
//  source, so you get the "obscured space between the dots" look from the reference.
//
//  Everything expensive is avoided on purpose:
//    - The source is sampled with a bilinear sampler, so a single texture read gives
//      us an averaged-ish color for the cell center. For a stronger "average the
//      whole cell" look we optionally take a tiny fixed tap pattern (still cheap).
//    - The dot mask is an analytic rounded-box SDF with a 1px (screen-space) smooth
//      edge — no texture lookups, no branches in the hot path.
//    - The optional gap blur is a small separable-ish box approximation done with a
//      handful of taps, gated by a uniform so it costs nothing when disabled.
//
//  This is written to be trivially portable: it has no dependency on the Swift side
//  beyond the `HalftoneUniforms` layout, which is mirrored exactly in Swift.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `HalftoneUniforms` in Swift. Keep field order/packing identical.
struct HalftoneUniforms {
    float2 resolution;        // drawable size in pixels
    float2 contentScale;      // (texelSize.x/resolution.x, ...) usually 1,1; lets the
                              // source texture differ in size from the drawable.

    float  cellSize;          // grid pitch in pixels (center-to-center spacing)
    float  dotScale;          // 0..1 fraction of the cell the dot fills (1 = touching)
    float  cornerRadius;      // 0..1 fraction of the dot half-size used as corner radius
                              //   0   => square dot
                              //   1   => circle/capsule
    float  edgeSoftness;      // px of antialiasing on the dot edge (>= ~0.75)

    float  shapeSides;        // reserved/blend control (kept for ABI stability)
    float  jitter;            // 0..1 positional jitter of dots (organic look)
    float  brightnessBoost;   // multiplies sampled dot color (bloom-ish pop)
    float  sampleAverage;     // 0 = single center tap, 1 = 5-tap cell average

    float4 gapColor;          // RGBA of the space between dots (premultiplied-friendly)
    float  gapBlur;           // 0 = off. >0 = radius in px of blur sampled behind gaps
    float  gapSourceMix;      // 0 = gap is pure gapColor, 1 = gap is blurred source
    float  dotOpacity;        // overall opacity of the dots
    float  time;              // seconds, for optional animated jitter

    float  gridAngle;         // radians, rotates the whole grid
    float  flipVertical;      // 0 = sample as-is, 1 = flip source vertically
    float  rippleActive;      // 0 = steady state (reveal = revealTo), 1 = wave in flight
    float  rippleRadius;      // px, expanding wavefront radius (= speed * elapsed)

    float2 rippleOrigin;      // px, tap point the wave emanates from
    float  ripplePush;        // px, peak radial displacement of the dots at the front
    float  rippleWidth;       // px, half-thickness of the Gaussian push ring

    float  rippleFlipBand;    // px, distance behind the front over which each dot flips in/out
    float  rippleWavelength;  // px, 0 = no oscillation; >0 = dispersive trailing ripples
    float  rippleDecay;       // px, e-folding length of the trailing ripples
    float  rippleFade;        // 0..1, global amplitude fade near the end of the animation

    float  revealFrom;        // 0/1, effect state behind→ the wave started from
    float  revealTo;          // 0/1, effect state the wave moves toward (steady when idle)
    float  ripplePhase;       // radians, phase of the dispersion oscillation
    float  monochrome;        // 0 = full colour dots, 1 = greyscale (luminance) dots
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle — 3 verts, no vertex buffer needed.
vertex VSOut halftone_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);   // (0,0) (2,0) (0,2)
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);                // flip Y so uv matches UIKit top-left
    return o;
}

// --- helpers ---------------------------------------------------------------

// Signed distance to a rounded box centered at origin with half-extents `b` and
// corner radius `r`. Negative inside, positive outside. Classic IQ formulation.
static inline float sdRoundBox(float2 p, float2 b, float r) {
    float2 q = abs(p) - b + r;
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

static inline float2 rotate2(float2 p, float c, float s) {
    return float2(p.x * c - p.y * s, p.x * s + p.y * c);
}

// cheap hash for jitter
static inline float2 hash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

// --- fragment --------------------------------------------------------------

fragment float4 halftone_fragment(VSOut in [[stage_in]],
                                  texture2d<float, access::sample> src [[texture(0)]],
                                  constant HalftoneUniforms& U [[buffer(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear,
                                    min_filter::linear,
                                    mip_filter::linear,
                                    address::clamp_to_edge);

    // Pixel coordinate of this fragment.
    float2 fragPx = in.uv * U.resolution;

    // --- ripple displacement ----------------------------------------------
    // Everything keys off the SIGNED distance from this fragment to the moving
    // wavefront ring (d<0 behind the front, d>0 ahead). The push is a Gaussian
    // ring (localised by `rippleWidth`) optionally modulated into a dispersive
    // wave train (`rippleWavelength`) that trails off behind the front over
    // `rippleDecay`. Every one of those parameters affects the result.
    float2 toOrigin = fragPx - U.rippleOrigin;
    float  distO    = length(toOrigin);
    float2 rdir     = distO > 1e-4 ? toOrigin / distO : float2(0.0);
    float  R        = U.rippleRadius;
    float  d        = distO - R;

    float amp = 0.0;
    if (U.rippleActive > 0.5 && U.ripplePush > 0.0) {
        float w        = max(U.rippleWidth, 1.0);
        float envelope = exp(-(d * d) / (w * w));                 // ring thickness (width)
        float behind   = max(0.0, -d);
        float trailing = exp(-behind / max(U.rippleDecay, 1.0));  // trailing falloff (decay)
        float wave     = 1.0;
        if (U.rippleWavelength > 0.5) {                            // oscillation (wavelength)
            float k = 6.2831853 / U.rippleWavelength;
            wave = cos(k * d - U.ripplePhase);
        }
        amp = U.ripplePush * envelope * trailing * wave * U.rippleFade;
    }
    // Inverse map: sampling inward makes the dots VISUALLY translate outward, so
    // the outermost dots slide past the view bounds and settle back as the ring
    // passes (the envelope returns each pixel to rest once the front moves on).
    float2 workPx = fragPx - rdir * amp;

    // Work in a rotated grid space if requested.
    float ca = cos(U.gridAngle), sa = sin(U.gridAngle);
    float2 center = U.resolution * 0.5;
    float2 gridPx = rotate2(workPx - center, ca, sa) + center;

    float cell = max(U.cellSize, 1.0);

    // Which cell are we in, and where inside it (-0.5..0.5).
    float2 cellIndex = floor(gridPx / cell);
    float2 cellOrigin = cellIndex * cell;
    float2 cellCenterPx = cellOrigin + cell * 0.5;

    // Optional per-cell jitter of the dot center.
    if (U.jitter > 0.0) {
        float2 h = hash22(cellIndex + floor(U.time));
        // smoothly animate between two random offsets
        float2 h2 = hash22(cellIndex + floor(U.time) + 1.0);
        float f = fract(U.time);
        float2 j = mix(h, h2, smoothstep(0.0, 1.0, f)) - 0.5;
        cellCenterPx += j * cell * U.jitter;
    }

    // --- sample the source color for this cell -----------------------------
    // Convert the cell center (in rotated grid space) back to screen space to
    // sample the source, because the source content is NOT rotated.
    float2 sampleScreenPx = rotate2(cellCenterPx - center, ca, -sa) + center;
    float2 baseUV = (sampleScreenPx / U.resolution) * U.contentScale;
    if (U.flipVertical > 0.5) {
        baseUV.y = U.contentScale.y - baseUV.y;
    }

    float4 dotColor;
    if (U.sampleAverage > 0.5) {
        // 5-tap cross average across the cell for a smoother, more "averaged" dot.
        float2 d = (cell * 0.30) / U.resolution * U.contentScale;
        float4 c = src.sample(linearSampler, baseUV);
        c += src.sample(linearSampler, baseUV + float2( d.x, 0));
        c += src.sample(linearSampler, baseUV + float2(-d.x, 0));
        c += src.sample(linearSampler, baseUV + float2(0,  d.y));
        c += src.sample(linearSampler, baseUV + float2(0, -d.y));
        dotColor = c * 0.2;
    } else {
        dotColor = src.sample(linearSampler, baseUV);
    }
    dotColor.rgb *= U.brightnessBoost;
    if (U.monochrome > 0.5) {
        float lum = dot(dotColor.rgb, float3(0.299, 0.587, 0.114));
        dotColor.rgb = float3(lum);
    }

    // --- raw (un-effected) colour for this fragment ------------------------
    float2 rawUV = in.uv * U.contentScale;
    if (U.flipVertical > 0.5) {
        rawUV.y = U.contentScale.y - rawUV.y;
    }
    float4 rawColor = src.sample(linearSampler, rawUV);

    // --- per-dot flip transition -------------------------------------------
    // As the wavefront sweeps over a cell, its dot flips in (or out) by rotating
    // around its vertical centre line. `flipFactor` 0 = edge-on (raw shows
    // through), 1 = full dot (halftone). Each cell flips based on when the front
    // reached it, over `rippleFlipBand` points behind the front.
    float flipFactor;
    if (U.rippleActive > 0.5) {
        float cellDist = length(sampleScreenPx - U.rippleOrigin);
        float fp = clamp((R - cellDist) / max(U.rippleFlipBand, 1.0), 0.0, 1.0);
        fp = smoothstep(0.0, 1.0, fp);
        flipFactor = mix(U.revealFrom, U.revealTo, fp);
    } else {
        flipFactor = U.revealTo;
    }
    flipFactor = clamp(flipFactor, 0.0, 1.0);
    // Horizontal scale of a card flip around the vertical axis: sin(flip * 90°).
    float hsquish = sin(flipFactor * 1.5707963);

    // --- dot shape mask (squished horizontally by the flip) ----------------
    float2 rel = gridPx - cellCenterPx;
    float halfExtent = cell * 0.5 * clamp(U.dotScale, 0.0, 1.0);
    float halfX = halfExtent * hsquish;
    float r = min(halfX, halfExtent) * clamp(U.cornerRadius, 0.0, 1.0);
    float sd = sdRoundBox(rel, float2(halfX, halfExtent), r);
    float aa = max(U.edgeSoftness, 0.5);
    float dotMask = (1.0 - smoothstep(-aa, aa, sd)) * clamp(U.dotOpacity, 0.0, 1.0);
    // Fully retract the dot when edge-on, so the raw state has no leftover slivers
    // from the antialiased zero-width box.
    dotMask *= smoothstep(0.0, 0.04, flipFactor);

    // --- the gap (space between dots) -------------------------------------
    float4 steadyGap = U.gapColor;
    if (U.gapBlur > 0.0 && U.gapSourceMix > 0.0) {
        // Small fixed-tap blur of the source for the gap. 9 taps, cheap & gated.
        float2 rpx = U.gapBlur / U.resolution * U.contentScale;
        float4 b = float4(0.0);
        b += src.sample(linearSampler, baseUV + float2(-rpx.x, -rpx.y));
        b += src.sample(linearSampler, baseUV + float2( 0.0,  -rpx.y));
        b += src.sample(linearSampler, baseUV + float2( rpx.x, -rpx.y));
        b += src.sample(linearSampler, baseUV + float2(-rpx.x,  0.0));
        b += src.sample(linearSampler, baseUV + float2( 0.0,   0.0)) * 2.0;
        b += src.sample(linearSampler, baseUV + float2( rpx.x,  0.0));
        b += src.sample(linearSampler, baseUV + float2(-rpx.x,  rpx.y));
        b += src.sample(linearSampler, baseUV + float2( 0.0,   rpx.y));
        b += src.sample(linearSampler, baseUV + float2( rpx.x,  rpx.y));
        b /= 10.0;
        steadyGap = mix(U.gapColor, b, clamp(U.gapSourceMix, 0.0, 1.0));
    }
    // Gaps fade from the raw content to the gap colour as the dots flip in.
    float4 gap = mix(rawColor, steadyGap, flipFactor);

    // Composite: dot over gap.
    return mix(gap, dotColor, dotMask);
}
