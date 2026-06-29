//
//  DotMatrixShaders.metal
//  DotMatrixEffect
//
//  Real-time "dot-matrix" post-process. Each output pixel figures out
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
//  beyond the `DotMatrixUniforms` layout, which is mirrored exactly in Swift.
//

#include <metal_stdlib>
using namespace metal;

// Mirrors `DotMatrixUniforms` in Swift. Keep field order/packing identical.
struct DotMatrixUniforms {
    float2 resolution;        // drawable size in pixels
    float2 contentScale;      // (texelSize.x/resolution.x, ...) usually 1,1; lets the
                              // source texture differ in size from the drawable.

    float  cellSize;          // base dot size in pixels
    float  dotScale;          // fraction of the base cell the dot fills (>1 = bigger)
    float  cornerRadius;      // 0..1 fraction of the dot half-size used as corner radius
                              //   0   => square dot
                              //   1   => circle/capsule
    float  edgeSoftness;      // px of antialiasing on the dot edge (>= ~0.75)

    float  dotSpacing;        // grid-pitch multiplier (>=1); pitch = cellSize * dotSpacing
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

    float  rippleEdge;        // px, softness of the reveal step at the wavefront
    float  rippleWavelength;  // px, 0 = no oscillation; >0 = dispersive trailing ripples
    float  rippleDecay;       // px, e-folding length of the trailing ripples
    float  rippleFade;        // 0..1, global amplitude fade near the end of the animation

    float  revealFrom;        // 0/1, effect state behind→ the wave started from
    float  revealTo;          // 0/1, effect state the wave moves toward (steady when idle)
    float  ripplePhase;       // radians, phase of the dispersion oscillation
    float  monochrome;        // 0 = full colour dots, 1 = greyscale (luminance) dots

    float2 dragOrigin;        // px, current drag point
    float  transparentBackground; // 0 = non-dot view is the raw image, 1 = transparent
    float  dragRadius;        // px, influence radius of the finger drag

    float2 dragVector;        // px, displacement the dragged dots follow (springy)
    float  revealMode;        // 0 radial, 1 diamond, 2 bars, 3 dissolve, 4 spiral, 5 venetian
    float  revealAngle;       // radians, direction for the bars/venetian reveal

    float  posterizeLevels;   // 0 = off; >=2 quantises each dot colour channel to N steps
    float  chromaticAberration; // px, RGB sampling split for the dot colour (0 = off)
    float  scanlineStrength;  // 0..1 darkening of alternating scanlines (0 = off)
    float  scanlineSpacing;   // px, period of the scanlines
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

// Fullscreen triangle — 3 verts, no vertex buffer needed.
vertex VSOut dotMatrix_vertex(uint vid [[vertex_id]]) {
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

// The per-fragment "front coordinate" the reveal wave compares against its radius
// `R`: behind the front a fragment shows `revealTo`, ahead `revealFrom`. Swapping
// the metric is what turns one ripple into many transition shapes.
static inline float revealFrontCoord(constant DotMatrixUniforms& U, float2 toOrigin,
                                     float distO, float2 fragPx) {
    if (U.revealMode < 0.5) {            // radial — expanding circle
        return distO;
    } else if (U.revealMode < 1.5) {     // diamond — expanding square (Chebyshev)
        return max(abs(toOrigin.x), abs(toOrigin.y));
    } else if (U.revealMode < 2.5) {     // bars — twin fronts sweeping along an axis
        float c = cos(U.revealAngle), s = sin(U.revealAngle);
        return abs(toOrigin.x * c + toOrigin.y * s);
    } else if (U.revealMode < 3.5) {     // dissolve — radial front roughened per cell
        float2 cell = floor(fragPx / max(U.cellSize, 1.0));
        float n = hash22(cell).x;
        return distO + (n - 0.5) * max(U.rippleEdge, 1.0) * 10.0;
    } else if (U.revealMode < 4.5) {     // spiral — radius wound by angle
        float ang = atan2(toOrigin.y, toOrigin.x);
        return distO + ang * max(U.rippleEdge, 1.0) * 3.0;
    } else {                             // venetian — repeating slats across an axis
        float c = cos(U.revealAngle), s = sin(U.revealAngle);
        float along = toOrigin.x * c + toOrigin.y * s;
        float slat = max(U.cellSize, 8.0) * 3.0;
        return distO * 0.15 + abs(fract(along / slat) - 0.5) * slat * 2.0;
    }
}

// --- fragment --------------------------------------------------------------

fragment float4 dotMatrix_fragment(VSOut in [[stage_in]],
                                  texture2d<float, access::sample> src [[texture(0)]],
                                  constant DotMatrixUniforms& U [[buffer(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear,
                                    min_filter::linear,
                                    mip_filter::linear,
                                    address::clamp_to_edge);

    // Pixel coordinate of this fragment.
    float2 fragPx = in.uv * U.resolution;

    // --- displacement: ripple ring + finger drag --------------------------
    // The ripple keys off the SIGNED distance to the moving wavefront ring (d<0
    // behind, d>0 ahead): a Gaussian ring (`rippleWidth`) optionally modulated
    // into a dispersive wave train (`rippleWavelength`) that trails off behind
    // the front (`rippleDecay`).
    float2 toOrigin = fragPx - U.rippleOrigin;
    float  distO    = length(toOrigin);
    float2 rdir     = distO > 1e-4 ? toOrigin / distO : float2(0.0);
    float  R        = U.rippleRadius;
    float  d        = distO - R;

    float amp = 0.0;
    if (U.rippleActive > 0.5 && U.ripplePush > 0.0) {
        float w        = max(U.rippleWidth, 1.0);
        float envelope = exp(-(d * d) / (w * w));
        float behind   = max(0.0, -d);
        float trailing = exp(-behind / max(U.rippleDecay, 1.0));
        float wave     = 1.0;
        if (U.rippleWavelength > 0.5) {
            wave = cos(6.2831853 / U.rippleWavelength * d - U.ripplePhase);
        }
        amp = U.ripplePush * envelope * trailing * wave * U.rippleFade;
    }
    float2 disp = rdir * amp;

    // Finger drag: dots near the touch follow the finger, falling off with
    // distance, so the field smears like paint on water dragged by a current.
    if (U.dragRadius > 0.5) {
        float2 toDrag = fragPx - U.dragOrigin;
        float fall = exp(-dot(toDrag, toDrag) / (U.dragRadius * U.dragRadius));
        disp += U.dragVector * fall;
    }
    // Inverse map: sampling inward shifts the dots outward / with the finger.
    float2 workPx = fragPx - disp;

    // Grid: pitch = base cell × spacing; the dot keeps the BASE size so spacing
    // and dot size are independent.
    float ca = cos(U.gridAngle), sa = sin(U.gridAngle);
    float2 center = U.resolution * 0.5;
    float2 gridPx = rotate2(workPx - center, ca, sa) + center;

    float pitch = max(U.cellSize * max(U.dotSpacing, 1.0), 1.0);
    float2 cellIndex = floor(gridPx / pitch);
    float2 cellCenterPx = cellIndex * pitch + pitch * 0.5;

    if (U.jitter > 0.0) {
        float2 h  = hash22(cellIndex + floor(U.time));
        float2 h2 = hash22(cellIndex + floor(U.time) + 1.0);
        float2 j  = mix(h, h2, smoothstep(0.0, 1.0, fract(U.time))) - 0.5;
        cellCenterPx += j * pitch * U.jitter;
    }

    // --- sample the cell colour --------------------------------------------
    float2 sampleScreenPx = rotate2(cellCenterPx - center, ca, -sa) + center;
    float2 baseUV = (sampleScreenPx / U.resolution) * U.contentScale;
    if (U.flipVertical > 0.5) baseUV.y = U.contentScale.y - baseUV.y;

    float4 dotColor;
    if (U.sampleAverage > 0.5) {
        float2 t = (pitch * 0.30) / U.resolution * U.contentScale;
        float4 c = src.sample(linearSampler, baseUV);
        c += src.sample(linearSampler, baseUV + float2( t.x, 0));
        c += src.sample(linearSampler, baseUV + float2(-t.x, 0));
        c += src.sample(linearSampler, baseUV + float2(0,  t.y));
        c += src.sample(linearSampler, baseUV + float2(0, -t.y));
        dotColor = c * 0.2;
    } else {
        dotColor = src.sample(linearSampler, baseUV);
    }
    // Chromatic aberration: split the R/B channels along the sampling axis.
    if (U.chromaticAberration > 0.05) {
        float2 off = float2(U.chromaticAberration, 0) / U.resolution * U.contentScale;
        dotColor.r = src.sample(linearSampler, baseUV + off).r;
        dotColor.b = src.sample(linearSampler, baseUV - off).b;
    }
    dotColor.rgb *= U.brightnessBoost;
    if (U.monochrome > 0.5) {
        dotColor.rgb = float3(dot(dotColor.rgb, float3(0.299, 0.587, 0.114)));
    }
    // Posterize: quantise each channel to N steps for a banded, retro look.
    if (U.posterizeLevels >= 1.5) {
        float n = U.posterizeLevels;
        dotColor.rgb = floor(dotColor.rgb * n) / max(n - 1.0, 1.0);
    }

    // --- raw (un-effected) colour for this fragment ------------------------
    float2 rawUV = in.uv * U.contentScale;
    if (U.flipVertical > 0.5) rawUV.y = U.contentScale.y - rawUV.y;
    float4 rawColor = src.sample(linearSampler, rawUV);

    // --- dot shape mask (full size) ----------------------------------------
    float2 rel = gridPx - cellCenterPx;
    float halfExtent = max(U.cellSize * 0.5 * U.dotScale, 0.0);
    float r = halfExtent * clamp(U.cornerRadius, 0.0, 1.0);
    float sd = sdRoundBox(rel, float2(halfExtent), r);
    float aa = max(U.edgeSoftness, 0.5);
    float dotMask = (1.0 - smoothstep(-aa, aa, sd)) * clamp(U.dotOpacity, 0.0, 1.0);

    // --- gap fill ----------------------------------------------------------
    float4 steadyGap = U.gapColor;
    if (U.gapBlur > 0.0 && U.gapSourceMix > 0.0) {
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

    // --- reveal: the wave sweeps between dots and the non-dot view ----------
    float reveal;
    if (U.rippleActive > 0.5) {
        float frontCoord  = revealFrontCoord(U, toOrigin, distO, fragPx);
        float behindFront = smoothstep(R + U.rippleEdge, R - U.rippleEdge, frontCoord);
        reveal = mix(U.revealFrom, U.revealTo, behindFront);
    } else {
        reveal = U.revealTo;
    }
    reveal = clamp(reveal, 0.0, 1.0);

    // The "non-dot" view (and the gaps) are the raw image, or transparent when
    // the transparent-background option is on — so the wave then toggles the dots
    // appearing/disappearing over nothing.
    float4 offColor = (U.transparentBackground > 0.5) ? float4(0.0) : rawColor;
    float4 gapFill  = (U.transparentBackground > 0.5) ? float4(0.0) : steadyGap;
    float4 onLook   = mix(gapFill, dotColor, dotMask);
    float4 outColor = mix(offColor, onLook, reveal);

    // Scanlines: darken alternating horizontal bands (CRT-ish). Only dims where the
    // effect is showing, so a transparent background stays clean.
    if (U.scanlineStrength > 0.001 && reveal > 0.001) {
        float period = max(U.scanlineSpacing, 2.0);
        float s = 0.5 + 0.5 * cos(6.2831853 * fragPx.y / period);
        outColor.rgb *= 1.0 - U.scanlineStrength * s * reveal;
    }
    return outColor;
}
