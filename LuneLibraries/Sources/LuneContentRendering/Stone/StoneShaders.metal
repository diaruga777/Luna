//
//  StoneShaders.metal
//  LuneContentRendering
//
//  Real-time "stone" post-process: the source is diffused by a scattered disk blur,
//  then tinted toward a stone colour with a centre→edge coverage gradient (clear at
//  the rim, coloured in the middle) and a fuzzy tumbled speckle. Two materials:
//  jellystone (pastel sea glass) and lune (milky, cool). A tap fires a ripple that
//  sweeps the effect in/out from the touch point.
//
//  Mirrors `StoneUniforms` in Swift — keep field order/packing identical (the two
//  structs are matched by field ORDER, not name).
//

#include <metal_stdlib>
using namespace metal;

struct StoneUniforms {
    float2 resolution;        // drawable size in pixels
    float2 contentScale;      // usually (1,1); lets the source differ in size

    float  blurRadius;        // px, radius of the frosted diffusion blur (glass softness)
    float  grain;             // 0..1, fuzzy tumbled speckle of beach glass
    float  distortion;         // 0..1, how far the coloured body reaches toward the rim
    float  translucency;      // 0..1, max coverage of the body over the raw image

    float  surfaceScale;       // px, softness of the body→clear gradient at the rim
    float  saturation;        // 0..n saturation multiplier
    float  brightness;        // brightness multiplier
    float  flipVertical;      // 0 = sample as-is, 1 = flip source vertically

    float4 tint;              // straight RGBA stone colour (a = tint strength)

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
    float  material;          // 0 = jellystone sea-glass, 1 = lune
    float  revealMode;        // 0 radial,1 diamond,2 bars,3 dissolve,4 spiral,5 venetian

    float  revealAngle;       // radians, direction for the bars/venetian reveal
    float  chromaticAberration; // px, RGB split applied to the frosted result (0 = off)
    float  scanlineStrength;  // 0..1 darkening of alternating scanlines (0 = off)
    float  scanlineSpacing;   // px, period of the scanlines
};

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut stone_vertex(uint vid [[vertex_id]]) {
    float2 p = float2((vid << 1) & 2, vid & 2);
    VSOut o;
    o.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
    o.uv = float2(p.x, 1.0 - p.y);
    return o;
}

// cheap per-fragment hash for the frost jitter
static inline float2 shash22(float2 p) {
    float3 p3 = fract(float3(p.xyx) * float3(0.1031, 0.1030, 0.0973));
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.xx + p3.yz) * p3.zy);
}

static inline float sluma(float3 c) { return dot(c, float3(0.299, 0.587, 0.114)); }

// Value noise + fbm, for the procedural stone surface (refraction normal + cloud
// inclusions). Cheap enough for a per-fragment fbm at 4 octaves.
static inline float vnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0 - 2.0 * f);
    float a = fract(sin(dot(i + float2(0, 0), float2(127.1, 311.7))) * 43758.5453);
    float b = fract(sin(dot(i + float2(1, 0), float2(127.1, 311.7))) * 43758.5453);
    float c = fract(sin(dot(i + float2(0, 1), float2(127.1, 311.7))) * 43758.5453);
    float d = fract(sin(dot(i + float2(1, 1), float2(127.1, 311.7))) * 43758.5453);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}
static inline float sfbm(float2 p) {
    float v = 0.0, a = 0.5;
    for (int i = 0; i < 4; i++) { v += a * vnoise(p); p *= 2.02; a *= 0.5; }
    return v;
}

// Per-fragment "front coordinate" the reveal wave compares against its radius `R`;
// swapping the metric turns the single ripple into several transition shapes.
static inline float stoneFrontCoord(constant StoneUniforms& U, float2 toOrigin,
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
        return distO + (shash22(cell).x - 0.5) * max(U.rippleEdge, 1.0) * 10.0;
    } else if (U.revealMode < 4.5) {     // spiral
        return distO + atan2(toOrigin.y, toOrigin.x) * max(U.rippleEdge, 1.0) * 3.0;
    } else {                             // venetian
        float c = cos(U.revealAngle), s = sin(U.revealAngle);
        float along = toOrigin.x * c + toOrigin.y * s;
        float slat = 96.0;
        return distO * 0.15 + abs(fract(along / slat) - 0.5) * slat * 2.0;
    }
}

fragment float4 stone_fragment(VSOut in [[stage_in]],
                                 texture2d<float, access::sample> src [[texture(0)]],
                                 constant StoneUniforms& U [[buffer(0)]]) {
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

    // --- stone material: transform the underlying pixels --------------------
    // A procedural fbm surface is the stone's uneven face: its gradient is the
    // surface normal, which REFRACTS the image beneath (we sample it displaced), and
    // a frosted scatter blur softens it — so the image is seen THROUGH the stone
    // rather than replaced by a flat colour.
    float surf = max(U.surfaceScale, 4.0);                // surface feature size, px
    float2 np  = workPx / surf;
    float  e   = 0.6;
    float  h0  = sfbm(np);
    float2 grad = float2(sfbm(np + float2(e, 0.0)) - h0,
                         sfbm(np + float2(0.0, e)) - h0); // surface slope = normal
    float2 refr = grad * U.distortion;                    // refraction offset, px

    // Frosted scatter (golden-angle disk), jittered by grain, along the refracted
    // coordinate.
    float2 jitter = (shash22(fragPx + U.time) - 0.5) * 2.0 * U.grain * U.blurRadius;
    float3 frost = float3(0.0);
    float  wsum  = 0.0;
    const int TAPS = 8;
    for (int i = 0; i < TAPS; i++) {
        float t   = (float(i) + 0.5) / float(TAPS);
        float ang = float(i) * 2.39996323;                // golden angle
        float2 off = (float2(cos(ang), sin(ang)) * sqrt(t) * U.blurRadius + jitter + refr) * texel;
        float wt  = 1.0 - 0.5 * t;
        frost += src.sample(linearSampler, baseUV + off).rgb * wt;
        wsum  += wt;
    }
    frost /= max(wsum, 1e-3);
    // Chromatic dispersion through the crystal: split R/B along the refraction vector.
    if (length(refr) > 0.01) {
        frost.r = src.sample(linearSampler, baseUV + (refr *  1.6) * texel).r;
        frost.b = src.sample(linearSampler, baseUV + (refr * -1.6) * texel).b;
    }

    // Tumbled-frost speckle + facet glints (steep surface slopes catch light).
    float speckle = (shash22(floor(fragPx)).x - 0.5) * U.grain;
    float facet   = clamp(length(grad) * U.distortion * 0.4, 0.0, 1.0);

    float3 color;
    if (U.material < 0.5) {
        // Jellystone — the object recast in frosted pastel sea glass: keep the
        // refracted structure but remap colour by luminance onto a pastel ramp
        // (shadows lift toward the tint, highlights toward white — translucent, never
        // pure black), then frost it. `tint.a` = recolour strength.
        float l = sluma(frost);
        float3 deep = mix(U.tint.rgb * 0.5, U.tint.rgb, 0.4);
        float3 lite = mix(U.tint.rgb, float3(1.0), 0.65);
        float3 pastel = mix(deep, lite, smoothstep(0.04, 0.96, l));
        color = mix(frost, pastel, clamp(U.tint.a, 0.0, 1.0));
        color = mix(color, float3(0.97, 0.98, 1.0), clamp(U.translucency, 0.0, 1.0) * 0.15);
        color += smoothstep(0.72, 1.0, l) * 0.12;         // soft subsurface bloom
        color += speckle * 0.16 + facet * 0.10;
    } else {
        // Lune — milky translucent crystal: desaturate toward a cool white, add
        // low-frequency cloud inclusions and a faint tint; the refracted image shows
        // through the haze. `translucency` = how milky/opaque the crystal is.
        float l = sluma(frost);
        float3 milky = mix(frost, float3(l), 0.5);        // desaturate
        float cloud = sfbm(np * 0.5 + 7.0);               // internal cloudiness
        float haze = clamp(U.translucency, 0.0, 1.0) * (0.3 + 0.45 * cloud);
        milky = mix(milky, float3(0.93, 0.95, 1.0), haze);
        milky = mix(milky, U.tint.rgb, clamp(U.tint.a, 0.0, 1.0) * 0.35);
        color = milky + speckle * 0.08 + facet * 0.16;    // brighter facet glints
    }

    color = mix(float3(sluma(color)), color, U.saturation);
    color *= U.brightness;

    // Chromatic aberration: pull the R/B channels from offset samples for a glassy
    // dispersion fringe (blended, so the frosted body is preserved).
    if (U.chromaticAberration > 0.05) {
        float2 off = float2(U.chromaticAberration, 0.0) * texel;
        float r = src.sample(linearSampler, baseUV + off).r * U.brightness;
        float b = src.sample(linearSampler, baseUV - off).b * U.brightness;
        color.r = mix(color.r, r, 0.6);
        color.b = mix(color.b, b, 0.6);
    }
    float4 effect = float4(clamp(color, 0.0, 1.0), 1.0);

    // --- reveal between raw and effect at the wavefront --------------------
    float reveal;
    if (U.rippleActive > 0.5) {
        float frontCoord = stoneFrontCoord(U, toOrigin, distO, fragPx);
        float behind = smoothstep(R + U.rippleEdge, R - U.rippleEdge, frontCoord);
        reveal = mix(U.revealFrom, U.revealTo, behind);
    } else {
        reveal = U.revealTo;
    }
    reveal = clamp(reveal, 0.0, 1.0);

    float4 outColor = mix(raw, effect, reveal);

    // Scanlines over the revealed effect (CRT-ish neon look).
    if (U.scanlineStrength > 0.001 && reveal > 0.001) {
        float period = max(U.scanlineSpacing, 2.0);
        float s = 0.5 + 0.5 * cos(6.2831853 * fragPx.y / period);
        outColor.rgb *= 1.0 - U.scanlineStrength * s * reveal;
    }
    return outColor;
}
