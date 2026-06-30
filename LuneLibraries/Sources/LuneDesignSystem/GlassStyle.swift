//
//  GlassStyle.swift
//  Lune
//

import UIKit

/// Liquid Glass styling for floating controls, falling back to material fills
/// on OS versions without the glass APIs.
public enum GlassStyle {
    /// The reading accent (RSVP reticule + ORP letter, scroll/chunk highlight),
    /// user-configurable via `ReaderSettings.accent`.
    public static var readingAccent: UIColor { ReaderSettings.accent.color }

    /// A small liquid-glass mark for the RSVP focal reticule — one sits above
    /// and one below the ORP letter. Glass-tinted with the reading accent
    /// (a glassy tint, not a solid fill). Falls back to a tinted material mark
    /// pre-iOS 26.
    public static func reticuleMark() -> UIVisualEffectView {
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
    public static func focusPanel() -> UIVisualEffectView {
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
    public static func circularButtonConfiguration(symbol: String, padding: CGFloat = 10) -> UIButton.Configuration {
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
    public static func barEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            return UIGlassEffect()
        }
        return UIBlurEffect(style: .systemMaterial)
    }

    // MARK: - Solid (de-glassed) fills
    //
    // These approximate the glass bar/button materials with solid, trait-aware colors,
    // for chrome that sits on SOLID color backgrounds where the live blur adds little
    // and interacts poorly with the Dot Matrix pixel-wipe transition (which can't
    // capture a UIVisualEffectView's content faithfully). They read like the material
    // they replace in both light and dark mode.

    /// A solid fill approximating the `barEffect()` material for header/bar backgrounds
    /// sitting on a solid screen. Slightly translucent so a hint of the content below
    /// shows through (matching the old material), and trait-aware so it reads correctly
    /// in light and dark mode.
    public static var solidBarColor: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 0.16, alpha: 0.94)
                : UIColor(white: 0.97, alpha: 0.94)
        }
    }

    /// A solid `.filled()` analog of `circularButtonConfiguration` for de-glassed
    /// circular chrome buttons. Same capsule shape, label foreground, and content
    /// insets; only the glass fill is swapped for a trait-aware translucent fill.
    public static func solidCircularButtonConfiguration(
        symbol: String, padding: CGFloat = 10
    ) -> UIButton.Configuration {
        var config = UIButton.Configuration.filled()
        config.baseBackgroundColor = solidButtonFill
        config.image = UIImage(systemName: symbol)
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(
            top: padding, leading: padding, bottom: padding, trailing: padding)
        return config
    }

    /// A trait-aware translucent fill for de-glassed circular/capsule buttons, tuned to
    /// read like the glass button material over the solid reader backgrounds.
    public static var solidButtonFill: UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(white: 1.0, alpha: 0.16)
                : UIColor(white: 0.0, alpha: 0.07)
        }
    }
}
