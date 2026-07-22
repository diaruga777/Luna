//
//  CarouselSourceBadge.swift
//  LunaDesignSystem
//
//  The source-identity mark on a mini-card scrubber chip: the site's favicon
//  for web saves, sender initials on a name-derived color for email imports,
//  or an SF-symbol fallback (mail without a sender, documents, sites whose
//  icon hasn't loaded yet).
//

import UIKit

public enum CarouselSourceBadge: Equatable {
    /// A fetched site icon (favicon / touch icon).
    case icon(UIImage)
    /// A named sender (e.g. an email import) — rendered as the name's initials
    /// on a color derived deterministically from the name.
    case sender(String)
    /// An SF Symbol fallback (e.g. "envelope.fill", "doc.text.fill", "globe").
    case symbol(String)

    /// Up to two initials for a sender name: the first letters of the first
    /// two words ("The Atlantic" → "TA", "substack" → "S"). Empty when the
    /// name has no letters/digits — callers should fall back to a symbol.
    public static func initials(fromName name: String) -> String {
        let words = name.split { !$0.isLetter && !$0.isNumber }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// A stable, name-derived chip color (FNV hash → hue), tuned separately
    /// for light and dark so white initials stay legible in both.
    public static func color(forName name: String) -> UIColor {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        let hue = CGFloat(hash % 360) / 360
        return UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(hue: hue, saturation: 0.48, brightness: 0.72, alpha: 1)
                : UIColor(hue: hue, saturation: 0.42, brightness: 0.78, alpha: 1)
        }
    }
}

/// Renders one `CarouselSourceBadge` in a small rounded square (designed for
/// the ~16pt badge slot of a mini-card scrubber chip). A nil badge shows a
/// neutral placeholder fill, so a chip whose favicon is still loading already
/// reads as a mini card.
public final class CarouselSourceBadgeView: UIView {

    private let imageView = UIImageView()
    private let initialsLabel = UILabel()

    public override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerCurve = .continuous
        clipsToBounds = true
        isUserInteractionEnabled = false

        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        imageView.clipsToBounds = true
        addSubview(imageView)

        initialsLabel.frame = bounds
        initialsLabel.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        initialsLabel.textAlignment = .center
        initialsLabel.textColor = .white
        initialsLabel.adjustsFontSizeToFitWidth = true
        initialsLabel.minimumScaleFactor = 0.6
        addSubview(initialsLabel)

        setBadge(nil)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height * 0.28
        initialsLabel.font = .systemFont(
            ofSize: bounds.height * 0.48, weight: .bold, width: .standard)
    }

    public func setBadge(_ badge: CarouselSourceBadge?) {
        imageView.image = nil
        imageView.isHidden = true
        initialsLabel.isHidden = true
        switch badge {
        case nil:
            backgroundColor = LunaColors.tertiaryFill
        case .icon(let image):
            // A subtle fill backs transparent favicons so they keep a card-like
            // footprint whatever their artwork.
            backgroundColor = LunaColors.tertiaryFill
            imageView.contentMode = .scaleAspectFill
            imageView.image = image
            imageView.isHidden = false
        case .sender(let name):
            backgroundColor = CarouselSourceBadge.color(forName: name)
            initialsLabel.text = CarouselSourceBadge.initials(fromName: name)
            initialsLabel.isHidden = false
        case .symbol(let symbolName):
            backgroundColor = LunaColors.quaternaryFill
            imageView.contentMode = .center
            imageView.tintColor = LunaColors.secondaryText
            imageView.image = UIImage(
                systemName: symbolName,
                withConfiguration: UIImage.SymbolConfiguration(
                    pointSize: bounds.height > 0 ? bounds.height * 0.52 : 8.5,
                    weight: .semibold))
            imageView.isHidden = false
        }
    }
}
