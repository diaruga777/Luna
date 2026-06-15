//
//  GlassStyle.swift
//  Clip
//

import UIKit

/// Liquid Glass styling for floating controls, falling back to material fills
/// on OS versions without the glass APIs.
enum GlassStyle {
    /// The reading accent — replaces the old red focus color across the readers,
    /// matching the app icon's indigo.
    static let readingAccent = UIColor.systemIndigo

    /// A capsule of liquid glass to sit behind the focused word in the RSVP
    /// reader (the word label is drawn on top, so it stays crisp). Falls back to
    /// a thin material capsule pre-iOS 26.
    static func focusPill() -> UIVisualEffectView {
        let pill: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = readingAccent.withAlphaComponent(0.16)
            pill = UIVisualEffectView(effect: glass)
            pill.cornerConfiguration = .capsule()
        } else {
            pill = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            pill.layer.cornerCurve = .continuous
            pill.clipsToBounds = true
        }
        return pill
    }

    /// A capsule glass configuration for circular floating buttons.
    static func circularButtonConfiguration(symbol: String, padding: CGFloat = 10) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
        } else {
            config = .filled()
            config.baseBackgroundColor = .secondarySystemBackground
        }
        config.image = UIImage(systemName: symbol)
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(
            top: padding, leading: padding, bottom: padding, trailing: padding)
        return config
    }

    /// The effect for floating bars (footer controls).
    static func barEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect()
        }
        return UIBlurEffect(style: .systemMaterial)
    }
}
