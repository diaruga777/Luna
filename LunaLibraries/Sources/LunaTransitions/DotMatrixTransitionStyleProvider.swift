//
//  DotMatrixTransitionStyleProvider.swift
//  LunaTransitions
//
//  Builds the GPU transition style from the fixed `DotMatrixTransitionStyle`
//  parameters and resolves the gap colour from the current trait collection (white in
//  light mode, black in dark mode). One place so every transition surface looks identical.
//

import LunaContentRendering
import LunaDesignSystem
import UIKit

public enum DotMatrixTransitionStyleProvider {
    /// The current pixel-wipe style, with the gap colour resolved for `traits`.
    public static func style(for traits: UITraitCollection) -> RabbitHoleTransitionStyle {
        let isDark = traits.userInterfaceStyle == .dark
        let g: Float = isDark ? 0 : 1   // gap = black in dark mode, white in light mode
        return RabbitHoleTransitionStyle(
            pixelSize: DotMatrixTransitionStyle.pixelSize,
            cornerRadius: DotMatrixTransitionStyle.cornerRadius,
            spacing: DotMatrixTransitionStyle.spacing,
            gapColor: SIMD4<Float>(g, g, g, 1),
            sweep: DotMatrixTransitionStyle.sweep,
            lag: DotMatrixTransitionStyle.lag,
            win: DotMatrixTransitionStyle.win)
    }
}
