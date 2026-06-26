//
//  GlassStyle.swift
//  Clip
//

import UIKit

/// Liquid Glass styling for floating controls, falling back to material fills
/// on OS versions without the glass APIs.
enum GlassStyle {
    /// The reading accent (RSVP reticule + ORP letter, scroll/chunk highlight),
    /// user-configurable via `ReaderSettings.accent`.
    static var readingAccent: UIColor { ReaderSettings.accent.color }

    /// A small liquid-glass mark for the RSVP focal reticule — one sits above
    /// and one below the ORP letter. Glass-tinted with the reading accent
    /// (a glassy tint, not a solid fill). Falls back to a tinted material mark
    /// pre-iOS 26.
    static func reticuleMark() -> UIVisualEffectView {
        let mark: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = readingAccent.withAlphaComponent(0.6)
            mark = UIVisualEffectView(effect: glass)
            mark.cornerConfiguration = .capsule()
        } else {
            mark = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            mark.contentView.backgroundColor = readingAccent.withAlphaComponent(0.45)
            mark.layer.cornerCurve = .continuous
            mark.clipsToBounds = true
        }
        return mark
    }

    /// A liquid-glass capsule "lens" for the chunk reader: a glassy pill the
    /// magnified chunk text sits inside, so the current words read as if under a
    /// reticule loupe. Faintly accent-tinted; falls back to a thin material pre-26.
    static func lensEffectView() -> UIVisualEffectView {
        let v: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = readingAccent.withAlphaComponent(0.16)
            v = UIVisualEffectView(effect: glass)
            v.cornerConfiguration = .capsule()
        } else {
            v = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
            v.contentView.backgroundColor = readingAccent.withAlphaComponent(0.14)
            v.layer.cornerCurve = .continuous
            v.clipsToBounds = true
        }
        return v
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
