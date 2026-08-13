//
//  SellerRowView.swift
//  LunaPriceUI
//

import LunaDesignSystem
import LunaFetch
import LunaModels
import UIKit

/// One seller in a tracked product's list: the site's icon, its NAME, and its
/// price — in that order, on one 44pt line.
///
/// The refresh time lives in the row's accessibility value rather than a
/// second visible line, and its history is the graph directly above.
///
/// The icon is the real favicon, fetched through the shared `SiteIconCache`
/// (the same cache the Reader's scrub chips use). Until it lands — and
/// forever, for a host that serves none — the row shows a lettered badge
/// rather than a generic compass, so each row still marks a distinct seller
/// instead of repeating the same glyph on every row.
public final class SellerRowView: UIControl {

    /// One row's height. The list's viewport is sized in multiples of this, so
    /// a partially visible row is always what says "there is more below".
    public static let height: CGFloat = 44

    private let iconView = UIImageView()
    private let initialLabel = UILabel()
    private let nameLabel = UILabel()
    private let priceLabel = UILabel()

    public private(set) var urlString: String = ""

    public init() {
        super.init(frame: .zero)
        buildLayout()
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout() {
        backgroundColor = LunaColors.secondaryBackground
        layer.cornerRadius = 12
        layer.cornerCurve = .continuous

        iconView.contentMode = .scaleAspectFit
        iconView.layer.cornerRadius = 5
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.isHidden = true

        initialLabel.font = .systemFont(ofSize: 12, weight: .bold)
        initialLabel.textColor = LunaSurfacePalette.baseColor(for: .priceTracker)
        initialLabel.textAlignment = .center
        initialLabel.backgroundColor = LunaColors.tertiaryFill
        initialLabel.layer.cornerRadius = 5
        initialLabel.layer.cornerCurve = .continuous
        initialLabel.clipsToBounds = true

        nameLabel.font = .preferredFont(forTextStyle: .subheadline)
        nameLabel.adjustsFontForContentSizeCategory = true
        nameLabel.textColor = LunaColors.primaryText
        nameLabel.lineBreakMode = .byTruncatingTail

        priceLabel.font = .monospacedDigitSystemFont(ofSize: 15, weight: .semibold)
        priceLabel.textColor = LunaColors.primaryText
        priceLabel.textAlignment = .right
        priceLabel.setContentHuggingPriority(.required, for: .horizontal)
        priceLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let badge = UIView()
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.addSubview(initialLabel)
        badge.addSubview(iconView)
        for view in [initialLabel, iconView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                view.topAnchor.constraint(equalTo: badge.topAnchor),
                view.bottomAnchor.constraint(equalTo: badge.bottomAnchor),
                view.leadingAnchor.constraint(equalTo: badge.leadingAnchor),
                view.trailingAnchor.constraint(equalTo: badge.trailingAnchor),
            ])
        }

        let stack = UIStackView(arrangedSubviews: [badge, nameLabel, priceLabel])
        stack.axis = .horizontal
        stack.alignment = .center
        stack.spacing = 10
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Self.height),
            badge.widthAnchor.constraint(equalToConstant: 22),
            badge.heightAnchor.constraint(equalToConstant: 22),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Fills the row in from one store listing. `isLowest` tints the price for
    /// the cheapest seller — with several retailers on screen the point of the
    /// list is which one is cheapest, and that should not require reading four
    /// numbers.
    public func configure(
        _ listing: PriceTrackerStore, isLowest: Bool, isFlashed: Bool
    ) {
        urlString = listing.urlString
        let name = SellerNaming.displayName(forURLString: listing.urlString)
        nameLabel.text = name
        initialLabel.text = SellerNaming.initial(forName: name)
        iconView.image = nil
        iconView.isHidden = true
        initialLabel.isHidden = false

        if let price = listing.lastPrice {
            priceLabel.text = PriceFormatting.string(amount: price, currency: listing.currency)
            priceLabel.textColor = isLowest
                ? LunaSurfacePalette.baseColor(for: .priceTracker) : LunaColors.primaryText
        } else {
            priceLabel.text = L10n.string("PriceTracker_productCard_noPriceValue")
            priceLabel.textColor = LunaColors.tertiaryText
        }
        // The merge flash: the seller this save just added, named where the eye
        // already is rather than in a banner.
        backgroundColor = isFlashed
            ? LunaSurfacePalette.baseColor(for: .priceTracker).withAlphaComponent(0.16)
            : LunaColors.secondaryBackground

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(name), \(priceLabel.text ?? "")"
        accessibilityValue = refreshDescription(for: listing)
        accessibilityHint = L10n.string("PriceTracker_productCard_openSiteHint")

        loadIcon(forURLString: listing.urlString)
    }

    /// The favicon, if the host has one. Guarded on the URL the row still holds
    /// when the fetch returns — rows are rebuilt on every store change, and a
    /// late icon must not land on whatever seller took this row's place.
    private func loadIcon(forURLString urlString: String) {
        guard let url = URL(string: urlString) else { return }
        SiteIconCache.shared.icon(forPageURL: url) { [weak self] image in
            guard let self, let image, self.urlString == urlString else { return }
            self.iconView.image = image
            self.iconView.isHidden = false
            self.initialLabel.isHidden = true
        }
    }

    public override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    private func refreshDescription(for listing: PriceTrackerStore) -> String {
        guard let refreshed = listing.lastRefreshed else {
            return L10n.string("PriceTracker_tracking_notYetRefreshed")
        }
        return L10n.string(
            "PriceTracker_tracking_refreshedFormat", Self.refreshedFormatter.string(from: refreshed))
    }

    // DateFormatter setup is expensive and this runs per row per reload.
    private static let refreshedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("MMM d, h:mm a")
        return formatter
    }()
}
