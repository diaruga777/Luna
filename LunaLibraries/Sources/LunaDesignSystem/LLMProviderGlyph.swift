//
//  LLMProviderGlyph.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// The two providers' marks, drawn in code as monochrome template images so
/// they take the surrounding label's colour and need no asset catalogue.
///
/// Deliberate approximations of the real logos, not copies: a hexagonal knot
/// for ChatGPT and an eight-armed burst for Claude. They are recognizable at
/// button size and carry no trademarked artwork (`claudedocs/llm-handoff.md`).
public enum LLMProviderGlyph {

    /// A template image of `provider`'s mark, `side` points square.
    public static func image(for provider: LLMProvider, side: CGFloat = 17) -> UIImage {
        let size = CGSize(width: side, height: side)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            UIColor.black.setStroke()
            UIColor.black.setFill()
            switch provider {
            case .chatGPT: drawKnot(in: size)
            case .claude: drawBurst(in: size)
            }
        }
        return image.withRenderingMode(.alwaysTemplate)
    }

    // MARK: - ChatGPT

    /// A hexagon with the three interior spokes that make the mark read as a
    /// knot rather than as a plain cell.
    private static func drawKnot(in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let radius = size.width / 2 - size.width * 0.08
        let line = max(1, size.width * 0.1)

        let hexagon = UIBezierPath()
        for corner in 0..<6 {
            let angle = CGFloat(corner) / 6 * 2 * .pi - .pi / 2
            let point = CGPoint(
                x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if corner == 0 { hexagon.move(to: point) } else { hexagon.addLine(to: point) }
        }
        hexagon.close()
        hexagon.lineWidth = line
        hexagon.lineJoinStyle = .round
        hexagon.stroke()

        let spokes = UIBezierPath()
        for spoke in 0..<3 {
            let angle = CGFloat(spoke) / 3 * 2 * .pi - .pi / 2
            spokes.move(to: center)
            spokes.addLine(to: CGPoint(
                x: center.x + radius * 0.62 * cos(angle),
                y: center.y + radius * 0.62 * sin(angle)))
        }
        spokes.lineWidth = line
        spokes.lineCapStyle = .round
        spokes.stroke()
    }

    // MARK: - Claude

    /// Eight arms from the centre, alternating long and short, with rounded
    /// ends.
    private static func drawBurst(in size: CGSize) {
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let long = size.width / 2 - size.width * 0.1
        let short = long * 0.66
        let line = max(1, size.width * 0.13)

        let arms = UIBezierPath()
        for arm in 0..<8 {
            let angle = CGFloat(arm) / 8 * 2 * .pi - .pi / 2
            let length = arm.isMultiple(of: 2) ? long : short
            arms.move(to: CGPoint(
                x: center.x + line * 0.3 * cos(angle),
                y: center.y + line * 0.3 * sin(angle)))
            arms.addLine(to: CGPoint(
                x: center.x + length * cos(angle), y: center.y + length * sin(angle)))
        }
        arms.lineWidth = line
        arms.lineCapStyle = .round
        arms.stroke()
    }
}
