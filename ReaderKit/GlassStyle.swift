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

    /// A subtle rounded glass panel sitting BEHIND the phrase reticule's two
    /// lines of text — a quiet focus frame, accent-tinted very lightly so the
    /// words on top stay crisp (unlike the single-word reticule marks, this sits
    /// under multi-word text, so the tint must be gentle).
    static func focusPanel() -> UIVisualEffectView {
        let panel: UIVisualEffectView
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = readingAccent.withAlphaComponent(0.12)
            panel = UIVisualEffectView(effect: glass)
        } else {
            panel = UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
            panel.contentView.backgroundColor = readingAccent.withAlphaComponent(0.08)
        }
        panel.layer.cornerRadius = 18
        panel.layer.cornerCurve = .continuous
        panel.clipsToBounds = true
        return panel
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
