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
        case reader
        case downloader
        case priceTracker
    }

    public static var currentSurface: Surface {
        surface(for: Bundle.main.bundleIdentifier)
    }

    public static func surface(for bundleIdentifier: String?) -> Surface {
        let components = Set((bundleIdentifier ?? "").lowercased().split(separator: "."))
        if components.contains("downloader") { return .downloader }
        if components.contains("pricetracker") { return .priceTracker }
        return .reader
    }

    /// The supplied, unmodified identity colour for the current app surface.
    public static var baseColor: UIColor { baseColor(for: currentSurface) }

    public static func baseColor(for surface: Surface) -> UIColor {
        switch surface {
        case .reader:
            return UIColor(red: 173 / 255, green: 181 / 255, blue: 246 / 255, alpha: 1)
        case .downloader:
            return UIColor(red: 204 / 255, green: 118 / 255, blue: 9 / 255, alpha: 1)
        case .priceTracker:
            return UIColor(red: 7 / 255, green: 255 / 255, blue: 157 / 255, alpha: 1)
        }
    }

    /// A very low-opacity wash for Liquid Glass. The glass remains primarily
    /// material/ambient; the app colour is only visible as a quiet cast.
    public static var glassTint: UIColor { baseColor.withAlphaComponent(0.14) }

    /// Progress needs more contrast than glass, while still avoiding a neon or
    /// solid-brand-colour treatment. Gently temper the base toward the foreground
    /// appropriate for the current appearance.
    public static let progressAccent = UIColor { traits in
        let base = baseColor.resolvedColor(with: traits)
        let temperingColor: UIColor = traits.userInterfaceStyle == .dark ? .white : .black
        let amount: CGFloat = traits.userInterfaceStyle == .dark ? 0.18 : 0.22
        return blended(base, toward: temperingColor, amount: amount)
    }

    private static func blended(
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
