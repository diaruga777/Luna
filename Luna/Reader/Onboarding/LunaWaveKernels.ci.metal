//
//  LunaWaveKernels.ci.metal
//  Luna
//
//  The save wave's five Core Image kernels, in Metal. The `.ci.metal` suffix is
//  load-bearing: Xcode's automatic Core Image rule compiles this file into
//  `LunaWaveKernels.ci.metallib` in the app bundle, which
//  `LiquidScreenWaveAnimator` loads by name. The same kernels exist there as
//  CIKL strings ONLY as a fallback for a bundle that somehow lacks the library —
//  CIKL is deprecated and an OS may refuse to compile it, which renders the
//  whole wave invisible; this library is the supported path.
//

#include <CoreImage/CoreImage.h>
using namespace metal;

extern "C" {
namespace coreimage {

    // The in-place press ripple: a circular band travelling out of the Action
    // Button, compressing pixels ahead of itself and stretching them behind.
    float2 lunaRadialWave(
        float2 center, float radius, float halfWidth, float amplitude,
        destination dest
    ) {
        float2 destinationCoord = dest.coord();
        float2 delta = destinationCoord - center;
        float distanceFromCenter = length(delta);
        float normalized = (distanceFromCenter - radius) / halfWidth;
        float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
        float compression = sin(normalized * 3.14159265359);
        float2 direction = delta / max(distanceFromCenter, 1.0);
        return destinationCoord - direction * (band * compression * amplitude);
    }

    // The blackout wave's warp: the same band, but travelling inward along the
    // signed distance to the highlighted link's rounded rect, and dying out
    // inside it.
    float2 lunaRoundedRectWave(
        float2 center, float2 halfSize, float cornerRadius,
        float radius, float halfWidth, float amplitude,
        destination dest
    ) {
        float2 destinationCoord = dest.coord();
        float2 local = destinationCoord - center;
        float2 innerHalfSize = max(halfSize - float2(cornerRadius), float2(0.0));
        float2 nearestDelta = local - clamp(local, -innerHalfSize, innerHalfSize);
        float nearestLength = length(nearestDelta);
        float signedDistance = nearestLength - cornerRadius;
        float normalized = (signedDistance - radius) / halfWidth;
        float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
        float compression = sin(normalized * 3.14159265359);
        float outside = smoothstep(-1.0, 1.0, signedDistance);
        float2 direction = nearestDelta / max(nearestLength, 1.0);
        return destinationCoord
            - direction * (band * compression * amplitude * outside);
    }

    // Blackens everything the inward wave has passed, leaving the highlighted
    // link untouched.
    float4 lunaBlackOutsideHighlightedLink(
        sample_t displaced, sample_t original,
        float2 center, float2 halfSize, float cornerRadius,
        float radius, float halfWidth,
        destination dest
    ) {
        float2 local = dest.coord() - center;
        float2 innerHalfSize = max(halfSize - float2(cornerRadius), float2(0.0));
        float2 nearestDelta = local - clamp(local, -innerHalfSize, innerHalfSize);
        float signedDistance = length(nearestDelta) - cornerRadius;
        float outside = smoothstep(-1.0, 1.0, signedDistance);
        float outsideDistance = max(signedDistance, 0.0);
        float coverage = smoothstep(
            radius - halfWidth, radius + halfWidth, outsideDistance);
        float4 blackened = mix(
            displaced, float4(0.0, 0.0, 0.0, 1.0), coverage);
        return mix(original, blackened, outside);
    }

    float4 lunaSaveCrossfade(
        sample_t source, sample_t destinationSample, float progress
    ) {
        return mix(source, destinationSample, progress);
    }

    // Lights the travelling front: brightens the ridge toward white, darkens
    // the trough — the lighting the warp alone cannot provide on flat colour.
    float4 lunaFirstWaveLighting(
        sample_t image, float2 center,
        float radius, float halfWidth, float strength,
        destination dest
    ) {
        float distanceFromCenter = length(dest.coord() - center);
        float normalized = (distanceFromCenter - radius) / halfWidth;
        float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
        float ridge = sin(normalized * 3.14159265359) * band;
        float3 color = image.rgb;
        color += max(ridge, 0.0) * strength * (float3(1.0) - color);
        color -= max(-ridge, 0.0) * strength * 0.72 * color;
        return float4(color, image.a);
    }

}
}
