//
//  PhotosAppGlyph.swift
//  LunaDesignSystem
//

import CoreGraphics
import UIKit

/// The Photos pinwheel, drawn — the mark on a "…to Photos" button.
///
/// A sandboxed app can't read another app's icon, and an SF Symbol
/// (`photo.badge.arrow.down`) reads as "an image", not as "the Photos library".
/// So the system icon's own construction is reproduced: eight rounded petals
/// radiating from a white hub, in the icon's own colours (sampled from it),
/// composited the way it composites them — `multiply` over white, so each
/// petal shows its exact colour and every overlap deepens into the lens shapes
/// the real mark has.
///
/// The white base travels WITH the flower (only inside the petals' union), so
/// the glyph looks right on Luna's near-black surfaces as well as on white.
/// Full colour in every button state (`.alwaysOriginal`), so it never takes the
/// button's tint.
public enum PhotosAppGlyph {

    /// Petal colours, clockwise from the top, sampled from the system icon.
    private static let petalColors: [UIColor] = [
        UIColor(red: 0xF4 / 255, green: 0xA3 / 255, blue: 0x41 / 255, alpha: 1),   // orange
        UIColor(red: 0xF9 / 255, green: 0xD6 / 255, blue: 0x55 / 255, alpha: 1),   // yellow
        UIColor(red: 0xAA / 255, green: 0xD6 / 255, blue: 0x4E / 255, alpha: 1),   // lime
        UIColor(red: 0x6C / 255, green: 0xD2 / 255, blue: 0x93 / 255, alpha: 1),   // mint
        UIColor(red: 0x58 / 255, green: 0xB6 / 255, blue: 0xF0 / 255, alpha: 1),   // blue
        UIColor(red: 0xAA / 255, green: 0xA0 / 255, blue: 0xDE / 255, alpha: 1),   // lavender
        UIColor(red: 0xF3 / 255, green: 0x86 / 255, blue: 0xB7 / 255, alpha: 1),   // pink
        UIColor(red: 0xF1 / 255, green: 0x7C / 255, blue: 0x76 / 255, alpha: 1),   // salmon
    ]

    // Petal geometry, as fractions of the glyph's side.
    private static let petalWidth: CGFloat = 0.31
    private static let petalLength: CGFloat = 0.46
    /// How far a petal's inner end stops short of the centre — the white hub.
    private static let hubInset: CGFloat = 0.05
    private static let hubRadius: CGFloat = 0.055

    /// Rendered images are identical for a given side, and the save button
    /// rebuilds its title on every state change — so keep them.
    private static var cache: [CGFloat: UIImage] = [:]

    /// The glyph at `side` points square, in full colour.
    @MainActor
    public static func image(side: CGFloat) -> UIImage {
        if let cached = cache[side] { return cached }
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { context in
            draw(in: context.cgContext, side: side)
        }.withRenderingMode(.alwaysOriginal)
        cache[side] = image
        return image
    }

    /// Pure CoreGraphics so the same drawing can be previewed off-device.
    public static func draw(in context: CGContext, side: CGFloat) {
        let center = CGPoint(x: side / 2, y: side / 2)
        let paths = (0..<petalColors.count).map { index -> CGPath in
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: CGFloat(index) / CGFloat(petalColors.count) * 2 * .pi)
            let rect = CGRect(
                x: -petalWidth * side / 2, y: hubInset * side,
                width: petalWidth * side, height: petalLength * side)
            return CGPath(
                roundedRect: rect, cornerWidth: petalWidth * side / 2,
                cornerHeight: petalWidth * side / 2, transform: &transform)
        }

        // The white the icon's translucent petals sit on, carried inside the
        // flower's own silhouette rather than a tile behind it.
        context.setBlendMode(.normal)
        context.setFillColor(UIColor.white.cgColor)
        for path in paths { context.addPath(path) }
        context.fillPath()

        context.setBlendMode(.multiply)
        for (path, color) in zip(paths, petalColors) {
            context.setFillColor(color.cgColor)
            context.addPath(path)
            context.fillPath()
        }

        // The hub the eight petals meet in, kept clean of their overlaps.
        context.setBlendMode(.normal)
        guard let hub = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                UIColor.white.cgColor, UIColor.white.cgColor,
                UIColor.white.withAlphaComponent(0).cgColor,
            ] as CFArray,
            locations: [0, 0.45, 1])
        else { return }
        context.drawRadialGradient(
            hub, startCenter: center, startRadius: 0,
            endCenter: center, endRadius: hubRadius * side, options: [])
    }
}
