//
//  ReaderDepth.swift
//  Lune
//

import UIKit

/// Background tinting for nested inline readers: each nesting level gets a
/// very slightly lighter (dark mode) or darker (light mode) background, with
/// 3–4 levels still holding good contrast against the label color.
public enum ReaderDepth {
    public static func backgroundColor(for depth: Int) -> UIColor {
        let level = min(max(depth, 0), 4)
        return UIColor { traits in
            if traits.userInterfaceStyle == .dark {
                let whites: [CGFloat] = [0.0, 0.07, 0.12, 0.16, 0.20]
                return UIColor(white: whites[level], alpha: 1)
            } else {
                let whites: [CGFloat] = [1.0, 0.96, 0.93, 0.90, 0.87]
                return UIColor(white: whites[level], alpha: 1)
            }
        }
    }
}
