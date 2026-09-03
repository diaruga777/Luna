//
//  LunaSurfacePalette.swift
//  LunaDesignSystem
//

import UIKit

/// The restrained per-app colour carried by shared Luna chrome.
///
/// Resolution uses bundle-id components rather than only the final suffix so
/// each app's Share, Action, and Safari extensions inherit their host's colour.
public enum LunaSurfacePalette {
    public enum Surface: Equatable {
        /// The central Luna app (bare bundle id — no content suffix).
        case luna
        case reader
        case downloader
        case priceTracker
        case vault
        case writer
    }

    public static var currentSurface: Surface {
        surface(for: Bundle.main.bundleIdentifier)
    }

    public static func surface(for bundleIdentifier: String?) -> Surface {
        let components = Set((bundleIdentifier ?? "").lowercased().split(separator: "."))
        if components.contains("downloader") { return .downloader }
        if components.contains("pricetracker") { return .priceTracker }
        if components.contains("reader") { return .reader }
        if components.contains("vault") { return .vault }
        if components.contains("writer") { return .writer }
        return .luna
    }

    /// The supplied, unmodified identity colour for the current app surface.
    public static var baseColor: UIColor { baseColor(for: currentSurface) }

    public static func baseColor(for surface: Surface) -> UIColor {
        switch surface {
        case .luna:
            return UIColor(red: 88 / 255, green: 86 / 255, blue: 214 / 255, alpha: 1)
        case .reader:
            return UIColor(red: 173 / 255, green: 181 / 255, blue: 246 / 255, alpha: 1)
        case .downloader:
            return UIColor(red: 204 / 255, green: 118 / 255, blue: 9 / 255, alpha: 1)
        case .priceTracker:
            return UIColor(red: 7 / 255, green: 255 / 255, blue: 157 / 255, alpha: 1)
        case .vault:
            return UIColor(red: 71 / 255, green: 170 / 255, blue: 255 / 255, alpha: 1)
        case .writer:
            // iA-blue caret and accent on the Luna sky (writer-app.md Q2).
            return UIColor(red: 30 / 255, green: 144 / 255, blue: 255 / 255, alpha: 1)
        }
    }

    /// A low-opacity wash for Liquid Glass. The glass stays material/ambient
    /// first, but the app colour now reads as a deliberate cast rather than a
    /// barely-there hint.
    public static var glassTint: UIColor { baseColor.withAlphaComponent(0.26) }

    /// Progress needs more contrast than glass, while still avoiding a neon or
    /// solid-brand-colour treatment. Temper the base only slightly toward the
    /// foreground appropriate for the current appearance — both appearances are
    /// dark now, so the tempering is toward white in each, and light.
    public static let progressAccent = UIColor { traits in
        let base = baseColor.resolvedColor(with: traits)
        let amount: CGFloat = traits.lunaSky == .night ? 0.10 : 0.06
        return blended(base, toward: .white, amount: amount)
    }

    // MARK: - Ink on a filled tint

    /// The near-black an identity colour is written on when it is bright.
    public static let inkDark = UIColor(
        red: 0x12 / 255, green: 0x12 / 255, blue: 0x1a / 255, alpha: 1)

    /// The text colour a surface FILLED with `tint` has to carry to stay
    /// legible — white on a deep one, `inkDark` on a bright one.
    ///
    /// The four identity colours span nearly the whole brightness range (the
    /// Price Tracker's green is a near-neon, the Reader's periwinkle is pale,
    /// the Luna indigo and the Downloader's amber are deep), so anything filled
    /// with one of them cannot also have a fixed text colour. The threshold is
    /// where white and `inkDark` tie on WCAG contrast, so each side is picked
    /// only where it actually wins — which is what lets the colour itself go on
    /// being exactly the app's, untempered.
    ///
    /// Hand-copied into `LunaSafari/Resources/content.js` as `tintForeground`
    /// (that target links no package) and pinned by `SafariSurfaceTintTests`.
    public static let inkCrossoverLuminance: CGFloat = 0.19

    public static func ink(on tint: UIColor) -> UIColor {
        relativeLuminance(of: tint) > inkCrossoverLuminance ? inkDark : .white
    }

    /// WCAG relative luminance. Resolved against the dark trait: these are
    /// fixed brand colours with no appearance variants, and a filled control
    /// must not change its text colour with the sky.
    public static func relativeLuminance(of color: UIColor) -> CGFloat {
        let resolved = color.resolvedColor(
            with: UITraitCollection(userInterfaceStyle: .dark))
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func linear(_ channel: CGFloat) -> CGFloat {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    // MARK: - Night sky

    /// The colour the night sky leans toward: the starfield's cast, and the
    /// chromatic lift of the light ("predawn") appearance.
    ///
    /// The central Luna app is deliberately achromatic — plain moonlight white —
    /// so its sky reads as the neutral parent of the three coloured children.
    public static var atmosphereTint: UIColor { atmosphereTint(for: currentSurface) }

    public static func atmosphereTint(for surface: Surface) -> UIColor {
        surface == .luna ? .white : baseColor(for: surface)
    }

    /// The deep blue of the sky at the very first hint of pre-sunrise light.
    private static let predawnSky = UIColor(red: 0.09, green: 0.12, blue: 0.24, alpha: 1)

    /// The app's own tint, cooled toward a pre-sunrise sky. Used as the hue of
    /// every light-appearance surface and of the stars themselves.
    public static var atmosphereCast: UIColor { atmosphereCast(for: currentSurface) }

    public static func atmosphereCast(for surface: Surface) -> UIColor {
        blended(atmosphereTint(for: surface), toward: predawnSky, amount: 0.6)
    }

    /// A near-black surface for the light ("predawn") appearance.
    ///
    /// `level` is the surface's mean channel value — the same 0…1 scale the dark
    /// ramp uses — so a light surface can be specified as "one notch above its
    /// dark twin" and still come out faintly coloured. The cast is normalised to
    /// unit mean and partly neutralised first, so `level` controls brightness on
    /// its own and no app's hue ever shouts.
    public static func predawnSurface(level: CGFloat, for surface: Surface) -> UIColor {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard atmosphereCast(for: surface).getRed(&r, green: &g, blue: &b, alpha: &a) else {
            return UIColor(white: level, alpha: 1)
        }
        let mean = max(0.0001, (r + g + b) / 3)
        // Unit-mean hue, then pulled most of the way back toward neutral.
        let neutralised: (CGFloat) -> CGFloat = { channel in
            let unit = channel / mean
            return unit + (1 - unit) * 0.55
        }
        return UIColor(
            red: min(1, neutralised(r) * level),
            green: min(1, neutralised(g) * level),
            blue: min(1, neutralised(b) * level),
            alpha: 1)
    }

    public static func predawnSurface(level: CGFloat) -> UIColor {
        predawnSurface(level: level, for: currentSurface)
    }

    public static func blended(
        _ source: UIColor, toward target: UIColor, amount: CGFloat
    ) -> UIColor {
        var sr: CGFloat = 0
        var sg: CGFloat = 0
        var sb: CGFloat = 0
        var sa: CGFloat = 0
        var tr: CGFloat = 0
        var tg: CGFloat = 0
        var tb: CGFloat = 0
        var ta: CGFloat = 0
        guard source.getRed(&sr, green: &sg, blue: &sb, alpha: &sa),
              target.getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        else { return source }
        let fraction = min(1, max(0, amount))
        return UIColor(
            red: sr + (tr - sr) * fraction,
            green: sg + (tg - sg) * fraction,
            blue: sb + (tb - sb) * fraction,
            alpha: sa + (ta - sa) * fraction)
    }
}
