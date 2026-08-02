//
//  OnboardingAttentionPulse.swift
//  Luna
//

import UIKit

/// The one breath a mock surface's call to action wears while the flow waits on
/// that tap: a slow swell with its light leading the movement.
///
/// Both places that need it take their rate and their curves from here — the
/// Messages pills that install the shortcut and open Settings, and the Safari
/// page's own "Activate Safari" button — so the demonstrations can never end up
/// breathing at different speeds. Only the light's RANGE differs, because the
/// mediums do: a pill's corona is dark between breaths and the breath itself
/// lights it, while the Safari button already wears a corona burning at full
/// strength, so its breath hangs BELOW that rather than swelling above it.
///
/// Durations are set on each keyframe animation rather than on a wrapping
/// group: a `CAAnimationGroup` does NOT scale its children to its own
/// duration, it clips them, so members left at the default ran a quarter-second
/// twitch inside a two-second cycle and the breath barely registered.
enum OnboardingAttentionPulse {
    /// One full breath, swell and settle.
    static let cycle: CFTimeInterval = 1.9
    static let peakScale: CGFloat = 1.065
    /// Without motion the light simply sits, lit, near the top of its range.
    static let reduceMotionGlowAlpha: CGFloat = 0.85
    /// The Safari button's corona is already burning and cannot brighten past
    /// full, so its breath falls to this between swells. The layer's model
    /// opacity stays 1: removing the pulse must leave the corona lit, not
    /// stranded at the trough.
    static let litCoronaTroughAlpha: CGFloat = 0.5

    /// The swell: up, held through the top of the breath, and back down.
    static func scale() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "transform.scale")
        animation.values = [1.0, peakScale, peakScale, 1.0]
        animation.keyTimes = [0, 0.42, 0.60, 1.0]
        return staged(animation, easeCount: 3)
    }

    /// The light leads the movement: totality is reached BEFORE the swell
    /// finishes, holds through the top of the breath, and burns back down as
    /// the surface settles — so the light is the event and the scale is the
    /// thing reacting to it, not the other way round.
    static func glow(from rest: CGFloat, to peak: CGFloat = 1) -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = [rest, peak, peak, rest, rest]
        animation.keyTimes = [0, 0.30, 0.60, 0.94, 1.0]
        return staged(animation, easeCount: 4)
    }

    private static func staged(
        _ animation: CAKeyframeAnimation,
        easeCount: Int
    ) -> CAKeyframeAnimation {
        let ease = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.timingFunctions = Array(repeating: ease, count: easeCount)
        animation.duration = cycle
        animation.repeatCount = .infinity
        return animation
    }
}
