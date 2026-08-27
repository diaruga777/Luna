//
//  LunaAppIconImage.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// Every Luna app's icon artwork, available to EVERY Luna app and extension.
///
/// A target's own `AppIcon*` appiconset only yields its own icon at runtime, so
/// the sibling icons ship separately: 96pt PNG trios in this module's resource
/// bundle, downscaled from the same committed 1024px masters the appiconsets
/// use. LunaDesignSystem is on every app's and extension's link path, so the
/// unsupported-save card can show whichever sibling owns a dropped link no
/// matter which app dropped it.
public enum LunaAppIconImage {

    /// The masters are square and opaque — iOS masks app icons itself — so a
    /// view drawing one has to apply the corner rounding. This is the standard
    /// iOS icon corner ratio (superellipse-approximating radius / side).
    public static let cornerRadiusRatio: CGFloat = 0.2237

    public static func image(for app: LunaApp) -> UIImage? {
        UIImage(named: assetName(for: app), in: .module, compatibleWith: nil)
    }

    private static func assetName(for app: LunaApp) -> String {
        switch app {
        case .luna: return "LunaAppIconLuna"
        case .reader: return "LunaAppIconReader"
        case .downloader: return "LunaAppIconDownloader"
        case .priceTracker: return "LunaAppIconPriceTracker"
        case .vault: return "LunaAppIconVault"
        }
    }
}

/// An app icon drawn the way iOS draws it: square artwork under a continuous
/// rounded-corner mask, with a hairline rim so a dark icon still reads as a
/// tile against the near-black card.
public final class LunaAppIconView: UIView {

    private let imageView = UIImageView()

    public init(app: LunaApp, side: CGFloat) {
        super.init(frame: CGRect(x: 0, y: 0, width: side, height: side))
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = side * LunaAppIconImage.cornerRadiusRatio
        layer.cornerCurve = .continuous
        clipsToBounds = true
        layer.borderWidth = 0.5

        imageView.image = LunaAppIconImage.image(for: app)
        imageView.contentMode = .scaleAspectFill
        imageView.frame = bounds
        imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(imageView)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
        ])

        applyBorderColor()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (view: LunaAppIconView, _: UITraitCollection) in view.applyBorderColor()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    private func applyBorderColor() {
        layer.borderColor = GlassStyle.glassBorderColor
            .resolvedColor(with: traitCollection).cgColor
    }
}
