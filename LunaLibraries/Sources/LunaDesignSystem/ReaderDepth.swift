//
//  ReaderDepth.swift
//  Luna
//

import UIKit

/// Background tinting for nested inline readers: each nesting level gets a
/// progressively lighter background in either appearance, with 3–4 levels
/// still holding good contrast against Luna's foreground color.
public enum ReaderDepth {
    public static func backgroundColor(for depth: Int) -> UIColor {
        let level = min(max(depth, 0), 4)
        return UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                let whites: [CGFloat] = [0.0, 0.07, 0.12, 0.16, 0.20]
                return UIColor(white: whites[level], alpha: 1)
            } else {
                let whites: [CGFloat] = [0.46, 0.51, 0.56, 0.61, 0.66]
                return UIColor(white: whites[level], alpha: 1)
            }
        }
    }
}
