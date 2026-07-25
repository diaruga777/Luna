//
//  ReaderDepth.swift
//  Luna
//

import UIKit

/// Background tinting for nested inline readers: each nesting level gets a
/// progressively lighter background in either appearance, with 3–4 levels
/// still holding good contrast against Luna's foreground color. The predawn
/// (light) ramp shadows the dark one one notch above it, tinted — see
/// `LunaColors` for why both appearances are night.
public enum ReaderDepth {
    private static let darkLevels: [CGFloat] = [0.00, 0.07, 0.12, 0.16, 0.20]
    private static let predawnLevels: [CGFloat] = [0.055, 0.105, 0.150, 0.190, 0.230]

    public static func backgroundColor(for depth: Int) -> UIColor {
        let level = min(max(depth, 0), 4)
        return LunaColors.night(dark: darkLevels[level], predawn: predawnLevels[level])
    }
}
