//
//  GlassStyle.swift
//  Luna
//

import LunaModels
import UIKit

/// The reticule's own geometry, published so the reader can place it with
/// clearance the ticks are guaranteed not to eat into (see `verticalPadding`).
public enum RSVPFocusReticuleMetrics {
    /// Thickness of each horizontal hairline.
    public static let lineThickness: CGFloat = 2.25
    /// Thickness and length of the inward ticks.
    public static let tickThickness: CGFloat = 2.25
    public static let tickLength: CGFloat = 4.5
    /// Clear space left between a tick's inner end and the ORP glyph's cap, so
    /// the cue frames the letter instead of crowding it.
    public static let glyphClearance: CGFloat = 6
    /// Distance from the glyph's cap edge out to the reticule's own edge —
    /// everything the lines and ticks occupy, plus the clearance.
    public static var verticalPadding: CGFloat { lineThickness + tickLength + glyphClearance }
    /// Reticule width, in multiples of a character's advance at the reader's
    /// font: wide enough to bridge the focal column's neighbours.
    public static let characterSpan: CGFloat = 4.5

    /// The reticule's frame around an ORP glyph whose cap box starts at
    /// `capTop`, centered on the focal column at `focalX`. The hairlines land
    /// `glyphClearance` + tick length clear of the cap on both sides.
    public static func frame(
        focalX: CGFloat, capTop: CGFloat, capHeight: CGFloat, characterWidth: CGFloat
    ) -> CGRect {
        let width = ceil(characterWidth * characterSpan)
        return CGRect(
            x: focalX - width / 2,
            y: capTop - verticalPadding,
            width: width,
            height: ceil(capHeight + verticalPadding * 2))
    }
}

/// The quiet focus bridge around RSVP's optimal-recognition-position letter.
///
/// Two broad hairlines fade from the reading accent at the focal column,
/// through neutral gray, to transparent. Tiny inward ticks point toward the
/// glyph without putting any line behind it.
private final class RSVPFocusReticuleView: UIView {
    private let topLine = CAGradientLayer()
    private let bottomLine = CAGradientLayer()
    private let topTick = CAGradientLayer()
    private let bottomTick = CAGradientLayer()

    init(accent: UIColor) {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        let neutral = UIColor(white: 0.72, alpha: 1)
        for line in [topLine, bottomLine] {
            line.colors = [
                accent.withAlphaComponent(0).cgColor,
                neutral.withAlphaComponent(0.24).cgColor,
                accent.withAlphaComponent(0.82).cgColor,
                neutral.withAlphaComponent(0.24).cgColor,
                accent.withAlphaComponent(0).cgColor,
            ]
            line.locations = [0, 0.28, 0.5, 0.72, 1]
            line.startPoint = CGPoint(x: 0, y: 0.5)
            line.endPoint = CGPoint(x: 1, y: 0.5)
            layer.addSublayer(line)
        }

        topTick.colors = [
            accent.withAlphaComponent(0.76).cgColor,
            accent.withAlphaComponent(0.30).cgColor,
        ]
        bottomTick.colors = topTick.colors.map { Array($0.reversed()) }
        for tick in [topTick, bottomTick] {
            tick.startPoint = CGPoint(x: 0.5, y: 0)
            tick.endPoint = CGPoint(x: 0.5, y: 1)
            layer.addSublayer(tick)
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        let lineHeight = RSVPFocusReticuleMetrics.lineThickness
        let tickWidth = RSVPFocusReticuleMetrics.tickThickness
        let tickLength = RSVPFocusReticuleMetrics.tickLength
        topLine.frame = CGRect(x: 0, y: 0, width: bounds.width, height: lineHeight)
        bottomLine.frame = CGRect(
            x: 0, y: max(0, bounds.height - lineHeight),
            width: bounds.width, height: lineHeight)
        topTick.frame = CGRect(
            x: (bounds.width - tickWidth) / 2, y: lineHeight,
            width: tickWidth, height: tickLength)
        bottomTick.frame = CGRect(
            x: (bounds.width - tickWidth) / 2,
            y: max(0, bounds.height - lineHeight - tickLength),
            width: tickWidth, height: tickLength)
        for line in [topLine, bottomLine] { line.cornerRadius = lineHeight / 2 }
        for tick in [topTick, bottomTick] { tick.cornerRadius = tickWidth / 2 }
    }
}

/// Liquid Glass styling for floating controls, falling back to material fills
/// on OS versions without the glass APIs.
public enum GlassStyle {
    /// The reading accent (RSVP reticule + ORP letter, scroll/chunk highlight),
    /// user-configurable via `ReaderSettings.accent`.
    public static var readingAccent: UIColor { ReaderSettings.accent.color }

    /// The fixed Luna brand accent — the indigo/periwinkle of the app icon. Used
    /// where the surface should read as "Luna" regardless of the user's reader
    /// highlight preference (which defaults to blue): the email sign-in screens,
    /// so their hero tile and action button match the purple app icon rather than
    /// looking like a generic blue template.
    public static let lunaBrandAccent = UIColor(red: 0.36, green: 0.31, blue: 0.85, alpha: 1)

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

    /// A compact RSVP focus cue for the full reader's Words mode. Its broad
    /// hairlines fade accent → gray → transparent, with two tiny inward ticks
    /// pointing toward the ORP glyph and no line behind the letter.
    public static func rsvpFocusReticule() -> UIView {
        RSVPFocusReticuleView(accent: readingAccent)
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
            config.baseBackgroundColor = LunaSurfacePalette.glassTint
        } else {
            config = .filled()
            config.baseBackgroundColor = LunaColors.secondaryBackground
        }
        config.image = UIImage(systemName: symbol)
        config.cornerStyle = .capsule
        config.baseForegroundColor = LunaColors.primaryText
        config.contentInsets = NSDirectionalEdgeInsets(
            top: padding, leading: padding, bottom: padding, trailing: padding)
        return config
    }

    /// The Apple Intelligence mark. `apple.intelligence` arrived in SF Symbols 6.2
    /// (iOS 18.4) and the deployment target is 18.0, so `sparkles` is a real
    /// fallback rather than belt-and-braces.
    public static var appleIntelligenceImage: UIImage? {
        UIImage(systemName: "apple.intelligence") ?? UIImage(systemName: "sparkles")
    }

    /// The ONE styling of "Retry with AI" — the Apple Intelligence glyph trailing
    /// the words as a sigil rather than leading as an icon.
    ///
    /// Shared so every error surface that offers the rescue reads identically: the
    /// in-app failed card, the Downloader's failed-download card, and the
    /// extension's failure card. They had drifted to three labels ("Try with
    /// Apple Intelligence", "Try Apple Intelligence", "Ask Apple Intelligence")
    /// and two icons; a user who sees the offer in two places should not have to
    /// work out whether it's the same offer.
    public static func retryWithAIConfiguration(
        title: String = L10n.string("Retry with AI"),
        prominent: Bool = true,
        compact: Bool = false
    ) -> UIButton.Configuration {
        var config = actionButtonConfiguration(
            title: title, symbol: "sparkles", prominent: prominent, compact: compact)
        if let intelligence = appleIntelligenceImage { config.image = intelligence }
        config.imagePlacement = .trailing
        return config
    }

    /// A capsule glass pill for a LABELLED action (symbol + title) — the button
    /// style for an action row. Exactly one button in a row should be
    /// `prominent`: it takes a Luna-tinted glass fill and full-strength label,
    /// the rest stay plain glass with a quieter label. `compact` is the smaller
    /// metric for two or three pills sharing one line.
    ///
    /// `tint` is the fill of a prominent pill. It defaults to the fixed Luna
    /// brand accent — the right choice wherever the surface should read as
    /// "Luna" — but a per-app surface (the extensions' own screens) passes
    /// `LunaSurfacePalette.baseColor` so its buttons carry the running app's
    /// own colour.
    public static func actionButtonConfiguration(
        title: String, symbol: String, prominent: Bool = false, compact: Bool = false,
        tint: UIColor = GlassStyle.lunaBrandAccent
    ) -> UIButton.Configuration {
        var config: UIButton.Configuration
        if #available(iOS 26.0, *) {
            config = .glass()
            config.baseBackgroundColor = prominent
                ? tint.withAlphaComponent(0.55) : LunaSurfacePalette.glassTint
        } else {
            config = .filled()
            config.baseBackgroundColor = prominent
                ? tint.withAlphaComponent(0.55) : LunaColors.tertiaryFill
        }
        config.image = UIImage(systemName: symbol)
        config.imagePadding = compact ? 5 : 8
        config.cornerStyle = .capsule
        config.baseForegroundColor = prominent
            ? LunaColors.primaryText : LunaColors.secondaryText
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: compact ? 12 : 15, weight: .semibold)
        config.contentInsets = compact
            ? NSDirectionalEdgeInsets(top: 10, leading: 8, bottom: 10, trailing: 8)
            : NSDirectionalEdgeInsets(top: 13, leading: 18, bottom: 13, trailing: 18)
        config.titleLineBreakMode = .byTruncatingTail
        var attributes = AttributeContainer()
        attributes.font = .systemFont(ofSize: compact ? 13 : 15, weight: .semibold)
        config.attributedTitle = AttributedString(title, attributes: attributes)
        return config
    }

    /// A subtle trait-aware stroke approximating a liquid-glass rim light, for
    /// hairline borders on card edges sitting over the screen background.
    public static var glassBorderColor: UIColor {
        UIColor { traits in
            traits.lunaSky == .night
                ? UIColor(white: 1.0, alpha: 0.14)
                : UIColor(white: 1.0, alpha: 0.12)
        }
    }

    /// The effect for floating bars (footer controls).
    public static func barEffect() -> UIVisualEffect {
        if #available(iOS 26.0, *) {
            let glass = UIGlassEffect()
            glass.tintColor = LunaSurfacePalette.glassTint
            return glass
        }
        return UIBlurEffect(style: .systemMaterial)
    }

    // MARK: - Solid (de-glassed) fills
    //
    // These approximate the glass bar/button materials with solid, trait-aware colors
    // for chrome that sits on solid backgrounds, where a live blur would add little.
    // They read like the material they replace in both light and dark mode.

    /// A solid fill approximating the `barEffect()` material for header/bar backgrounds
    /// sitting on a solid screen. Slightly translucent so a hint of the content below
    /// shows through (matching the old material), and trait-aware so it reads correctly
    /// in light and dark mode.
    public static var solidBarColor: UIColor {
        UIColor { traits in
            traits.lunaSky == .night
                ? UIColor(white: 0.16, alpha: 0.94)
                : LunaSurfacePalette.predawnSurface(level: 0.195)
                    .withAlphaComponent(0.94)
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
        config.baseForegroundColor = LunaColors.primaryText
        config.contentInsets = NSDirectionalEdgeInsets(
            top: padding, leading: padding, bottom: padding, trailing: padding)
        return config
    }

    /// A trait-aware translucent fill for de-glassed circular/capsule buttons, tuned to
    /// read like the glass button material over the solid reader backgrounds.
    private static var solidButtonFill: UIColor {
        UIColor { traits in
            traits.lunaSky == .night
                ? UIColor(white: 1.0, alpha: 0.16)
                : UIColor(white: 1.0, alpha: 0.14)
        }
    }
}
