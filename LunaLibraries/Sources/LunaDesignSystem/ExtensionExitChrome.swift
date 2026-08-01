//
//  ExtensionExitChrome.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// The ONE exit affordance a Luna extension surface shows: a floating Liquid
/// Glass circle in the bottom-right corner, carrying the host app's own tint.
///
/// Extensions live in someone else's sheet, where a navigation bar exists only
/// to hold a "Done" — a whole bar of chrome for one control, at the far side of
/// the screen from the thumb. The button replaces that bar: it sits where the
/// hand already is, over the content rather than above it, and it looks the
/// same in every extension screen (the media save screen, the action
/// extension's status screen, the in-sheet price editor), so leaving is one
/// gesture the user learns once.
///
/// `symbol` defaults to a checkmark — the affirmative exit after something was
/// saved. A surface that exits from a FAILURE passes `xmark` instead; a
/// checkmark over an error message would claim a success that didn't happen.
public enum ExtensionExitButton {

    /// Distance from the safe area's bottom-right corner.
    public static let edgeInset: CGFloat = 20

    /// Adds the button to `viewController.view`, pinned to the bottom-right of
    /// the safe area. Returned so a caller can hide it while a modal state is up.
    @MainActor
    @discardableResult
    public static func install(
        in viewController: UIViewController,
        symbol: String = "checkmark",
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = make(symbol: symbol, accessibilityLabel: accessibilityLabel, action: action)
        let view = viewController.view!
        view.addSubview(button)
        NSLayoutConstraint.activate([
            button.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -edgeInset),
            button.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -edgeInset),
        ])
        return button
    }

    /// The button on its own, for a host that positions it itself.
    @MainActor
    public static func make(
        symbol: String = "checkmark",
        accessibilityLabel: String? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        let button = UIButton(type: .system)
        var config = GlassStyle.circularButtonConfiguration(symbol: symbol, padding: 15)
        config.baseForegroundColor = LunaSurfacePalette.progressAccent
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 19, weight: .semibold)
        button.configuration = config
        button.accessibilityLabel = accessibilityLabel ?? L10n.string("Done")
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        button.translatesAutoresizingMaskIntoConstraints = false
        return button
    }
}

/// A capsule Liquid Glass mark stating what just happened — "✓ Saved to Luna"
/// — carrying the host app's tint on the glyph.
///
/// Replaces the loose 44pt SF Symbol + label that each confirmation screen drew
/// for itself: one pill reads as a single object, takes a third of the vertical
/// space, and matches the glass the rest of the extension chrome is made of.
public final class GlassConfirmationBadge: UIView {

    public init(symbol: String = "checkmark.circle.fill", title: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        let glass = UIVisualEffectView(effect: GlassStyle.barEffect())
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.clipsToBounds = true
        if #available(iOS 26.0, *) {
            glass.cornerConfiguration = .capsule()
        } else {
            glass.layer.cornerCurve = .continuous
        }
        addSubview(glass)

        let mark = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)))
        mark.tintColor = LunaSurfacePalette.progressAccent
        mark.contentMode = .center
        mark.setContentHuggingPriority(.required, for: .horizontal)

        let label = UILabel()
        label.text = title
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textColor = LunaColors.primaryText
        label.numberOfLines = 1

        let row = UIStackView(arrangedSubviews: [mark, label])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView.addSubview(row)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            // Hugs its content, centred in whatever width it's given.
            glass.centerXAnchor.constraint(equalTo: centerXAnchor),
            glass.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
            glass.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: glass.contentView.topAnchor, constant: 11),
            row.bottomAnchor.constraint(equalTo: glass.contentView.bottomAnchor, constant: -11),
            row.leadingAnchor.constraint(equalTo: glass.contentView.leadingAnchor, constant: 18),
            row.trailingAnchor.constraint(equalTo: glass.contentView.trailingAnchor, constant: -20),
        ])

        // Pre-iOS 26 the capsule has to be maintained by hand.
        if #unavailable(iOS 26.0) {
            glassForRounding = glass
        }
    }

    private weak var glassForRounding: UIVisualEffectView?

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override func layoutSubviews() {
        super.layoutSubviews()
        guard let glassForRounding else { return }
        glassForRounding.layer.cornerRadius = glassForRounding.bounds.height / 2
    }
}
