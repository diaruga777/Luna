//
//  HalftoneTransitionStyleProvider.swift
//  ClipTransitions
//
//  Builds the GPU transition style from the persisted `HalftoneTransitionSettings`
//  and resolves the gap colour from the current trait collection (white in light
//  mode, black in dark mode). One place so every transition surface looks identical.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public enum HalftoneTransitionStyleProvider {
    /// The current pixel-wipe style, with the gap colour resolved for `traits`.
    public static func style(for traits: UITraitCollection) -> RabbitHoleTransitionStyle {
        let isDark = traits.userInterfaceStyle == .dark
        let g: Float = isDark ? 0 : 1   // gap = black in dark mode, white in light mode
        return RabbitHoleTransitionStyle(
            pixelSize: HalftoneTransitionSettings.pixelSize,
            cornerRadius: HalftoneTransitionSettings.cornerRadius,
            spacing: HalftoneTransitionSettings.spacing,
            gapColor: SIMD4<Float>(g, g, g, 1),
            lag: HalftoneTransitionSettings.lag,
            window: HalftoneTransitionSettings.window,
            monochrome: HalftoneTransitionSettings.monochrome)
    }
}
