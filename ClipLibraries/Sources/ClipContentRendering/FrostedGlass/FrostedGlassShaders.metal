//
//  FrostedGlassShaders.metal
//  FrostedGlassEffect
//
//  Real-time "neon lights through frosted glass" post-process. The source content
//  is diffused by a scattered disk blur (the frosting), then its bright/saturated
//  regions are bloomed into a soft neon glow, optionally tinted. A wave transition
//  (shared in spirit with the halftone effect) reveals the effect from a tap point
//  with a radial ripple through the "glass".
//
//  Mirrors `FrostedUniforms` in Swift — keep field order/packing identical.
//

#include <metal_stdlib>
using namespace metal;

struct FrostedUniforms {
    float2 resolution;        // drawable size in pixels
    float2 contentScale;      // usually (1,1); lets the source differ in size

    float  frostRadius;       // px, radius of the frosted diffusion blur
    float  frostScatter;      // 0..1, per-pixel random jitter of the frost taps
    float  glowThreshold;     // 0..1, luminance above which a pixel blooms
    float  glowIntensity;     // strength the neon glow is added back

    float  glowRadius;        // px, spread of the neon glow
    float  saturation;        // 0..n saturation multiplier
    float  brightness;        // brightness multiplier
    float  flipVertical;      // 0 = sample as-is, 1 = flip source vertically

    float4 tint;              // straight RGBA neon tint (a = tint strength)

    float  time;              // seconds (reserved / animated noise)
    float  rippleActive;      // 0 = steady (reveal = revealTo), 1 = wave in flight
    float  rippleRadius;      // px, expanding wavefront radius (= speed * elapsed)
    float  rippleEdge;        // px, softness of the reveal step at the wavefront

    float2 rippleOrigin;      // px, tap point the wave emanates from
    float  ripplePush;        // px, peak radial displacement at the front
    float  rippleWidth;       // px, half-thickness of the push ring

    float  rippleWavelength;  // px, 0 = single ring; >0 = dispersive ripples
    float  rippleDecay;       // px, trailing-ripple falloff length
    float  rippleFade;        // 0..1, global amplitude fade near the end
    float  revealFrom;        // 0/1, effect state the wave started from

    float  revealTo;          // 0/1, effect state the wave moves toward (steady)
    float  ripplePhase;       // radians, dispersion oscillation phase
    float  additiveGlow;      // 0 = screen blend the glow, 1 = additive
    float  revealMode;        // 0 radial,1 diamond,2 bars,3 dissolve,4 spiral,5 venetian

    float  revealAngle;       // radians, direction for the bars/venetian reveal
    float  _pad0;
    float  _pad1;
    float  _pad2;
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut frosted_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// cheap per-fragment hash for the frost jitter
static inline float2 fhash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static inline float fluma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// Per-fragment "front coordinate" the reveal wave compares against its radius `R`;
// swapping the metric turns the single ripple into several transition shapes.
static inline float frostedFrontCoord(constant FrostedUniforms& U, float2 toOrigin,
                                       float distO, float2 fragPx) {
    if (U.revealMode < 0.5) {            // radial
        return distO;
    } else if (U.revealMode < 1.5) {     // diamond
        return max(abs(toOrigin.x), abs(toOrigin.y));
    } else if (U.revealMode < 2.5) {     // bars
        float c = cos(U.revealAngle), s = sin(U.revealAngle);
        return abs(toOrigin.x * c + toOrigin.y * s);
    } else if (U.revealMode < 3.5) {     // dissolve
        float2 cell = floor(fragPx / 24.0);
        return distO + (fhash22(cell).x - 0.5) * max(U.rippleEdge, 1.0) * 10.0;
    } else if (U.revealMode < 4.5) {     // spiral
        return distO + atan2(toOrigin.y, toOrigin.x) * max(U.rippleEdge, 1.0) * 3.0;
    } else {                             // venetian
        float c = cos(U.revealAngle), s = sin(U.revealAngle);
        float along = toOrigin.x * c + toOrigin.y * s;
        float slat = 96.0;
        return distO * 0.15 + abs(fract(along / slat) - 0.5) * slat * 2.0;
    }
}

fragment float4 frosted_fragment(VSOut in [[stage_in]],
                                 texture2d<float, access::sample> src [[texture(0)]],
                                 constant FrostedUniforms& U [[buffer(0)]]) {
    constexpr sampler linearSampler(mag_filter::linear, min_filter::linear,
                                    mip_filter::linear, address::clamp_to_edge);

    float2 fragPx = in.uv * U.resolution;

    // --- ripple displacement (radial ring, optional dispersion) ------------
    float2 toOrigin = fragPx - U.rippleOrigin;
    float  distO    = length(toOrigin);
    float2 rdir     = distO > 1e-4 ? toOrigin / distO : float2(0.0);
    float  R        = U.rippleRadius;
    float  d        = distO - R;

    float amp = 0.0;
    if (U.rippleActive > 0.5 && U.ripplePush > 0.0) {
        float w        = max(U.rippleWidth, 1.0);
        float envelope = exp(-(d * d) / (w * w));
        float trailing = exp(-max(0.0, -d) / max(U.rippleDecay, 1.0));
        float wave     = 1.0;
        if (U.rippleWavelength > 0.5) {
            wave = cos(6.2831853 / U.rippleWavelength * d - U.ripplePhase);
        }
        amp = U.ripplePush * envelope * trailing * wave * U.rippleFade;
    }

    // Displaced sample coordinate (the glass "bends" the light near the front).
    float2 workPx = fragPx - rdir * amp;
    float2 baseUV = (workPx / U.resolution) * U.contentScale;
    if (U.flipVertical > 0.5) baseUV.y = U.contentScale.y - baseUV.y;

    // Raw (un-effected) colour, sampled undisplaced.
    float2 rawUV = in.uv * U.contentScale;
    if (U.flipVertical > 0.5) rawUV.y = U.contentScale.y - rawUV.y;
    float4 raw = src.sample(linearSampler, rawUV);

    float2 texel = U.contentScale / U.resolution;

    // --- frosted glass: jittered disk blur (golden-angle spiral) -----------
    float2 jitter = (fhash22(fragPx + U.time) - 0.5) * 2.0 * U.frostScatter * U.frostRadius;
    float3 frost = float3(0.0);
    float  wsum  = 0.0;
    const int FROST_TAPS = 16;
    for (int i = 0; i < FROST_TAPS; i++) {
        float t   = (float(i) + 0.5) / float(FROST_TAPS);
        float ang = float(i) * 2.39996323;            // golden angle
        float2 off = float2(cos(ang), sin(ang)) * sqrt(t) * U.frostRadius + jitter;
        float wt  = 1.0 - 0.5 * t;                     // weight the centre a bit more
        frost += src.sample(linearSampler, baseUV + off * texel).rgb * wt;
        wsum  += wt;
    }
    frost /= max(wsum, 1e-3);

    // --- neon glow: bloom the bright regions -------------------------------
    float3 glow = float3(0.0);
    const int GLOW_TAPS = 12;
    float invThresh = 1.0 / max(1.0 - U.glowThreshold, 1e-3);
    for (int i = 0; i < GLOW_TAPS; i++) {
        float t   = (float(i) + 0.5) / float(GLOW_TAPS);
        float ang = float(i) * 2.39996323 + 0.6;
        float2 off = float2(cos(ang), sin(ang)) * sqrt(t) * U.glowRadius;
        float3 c  = src.sample(linearSampler, baseUV + off * texel).rgb;
        float bright = max(0.0, fluma(c) - U.glowThreshold) * invThresh;
        glow += c * bright;
    }
    glow /= float(GLOW_TAPS);
    glow *= U.glowIntensity;
    // Tint the glow toward the neon colour.
    glow *= mix(float3(1.0), U.tint.rgb, U.tint.a);

    // --- compose: saturate + brighten the frosted base, then add the glow --
    float3 color = frost;
    color = mix(float3(fluma(color)), color, U.saturation);
    color *= U.brightness;

    if (U.additiveGlow > 0.5) {
        color += glow;
    } else {
        color = 1.0 - (1.0 - clamp(color, 0.0, 1.0)) * (1.0 - clamp(glow, 0.0, 1.0)); // screen
    }
    float4 effect = float4(clamp(color, 0.0, 1.0), 1.0);

    // --- reveal between raw and effect at the wavefront --------------------
    float reveal;
    if (U.rippleActive > 0.5) {
        float frontCoord = frostedFrontCoord(U, toOrigin, distO, fragPx);
        float behind = smoothstep(R + U.rippleEdge, R - U.rippleEdge, frontCoord);
        reveal = mix(U.revealFrom, U.revealTo, behind);
    } else {
        reveal = U.revealTo;
    }
    reveal = clamp(reveal, 0.0, 1.0);

    return mix(raw, effect, reveal);
}
