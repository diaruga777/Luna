//
//  OnboardingExtensionCallout.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// A noninteractive-page-era mock of the system liquid-glass extension
/// popover: it grows out of the URL bar's leading page-menu item, shows this
/// app's icon and name, one line of explanation, and the single real action.
final class OnboardingExtensionCalloutView: UIView {
    var onActivate: (() -> Void)?

    static let appDisplayName: String = {
        let info = Bundle.main
        return (info.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (info.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? "Luna"
    }()

    private let glass = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let arrow = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let iconView = UIImageView(
        image: OnboardingAppIcon.image() ?? UIImage(systemName: "moon.stars.fill"))
    private let nameLabel = UILabel()
    private let explainer = UILabel()
    private let activateButton = UIButton(type: .system)

    /// The height of the down-pointing arrow diamond that hangs below `bounds`.
    static let arrowHeight: CGFloat = 11

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityIdentifier = "onboarding.safari.extensionCallout"

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.55
        layer.shadowRadius = 28
        layer.shadowOffset = CGSize(width: 0, height: 14)

        // A rotated glass square tucked under the card reads as the popover
        // arrow while staying on the same material as the body.
        arrow.layer.cornerRadius = 4
        arrow.layer.cornerCurve = .continuous
        arrow.clipsToBounds = true
        arrow.transform = CGAffineTransform(rotationAngle: .pi / 4)
        addSubview(arrow)

        glass.layer.cornerRadius = 26
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.layer.borderWidth = 1
        glass.layer.borderColor = GlassStyle.glassBorderColor.cgColor
        addSubview(glass)

        iconView.contentMode = .scaleAspectFill
        iconView.layer.cornerRadius = 10
        iconView.layer.cornerCurve = .continuous
        iconView.clipsToBounds = true
        iconView.accessibilityIdentifier = "onboarding.safari.callout.appIcon"
        glass.contentView.addSubview(iconView)

        nameLabel.text = Self.appDisplayName
        nameLabel.font = .systemFont(ofSize: 18, weight: .semibold)
        nameLabel.textColor = .white
        nameLabel.accessibilityIdentifier = "onboarding.safari.callout.appName"
        glass.contentView.addSubview(nameLabel)

        explainer.text = "Luna in Safari automatically gives you "
            + "the web experience you want"
        explainer.font = .systemFont(ofSize: 15, weight: .regular)
        explainer.textColor = UIColor.white.withAlphaComponent(0.82)
        explainer.numberOfLines = 3
        explainer.accessibilityIdentifier = "onboarding.safari.callout.explainer"
        glass.contentView.addSubview(explainer)

        activateButton.configuration = GlassStyle.actionButtonConfiguration(
            title: "Activate Safari",
            symbol: "safari.fill",
            prominent: true)
        activateButton.accessibilityLabel = "Activate Safari"
        activateButton.accessibilityIdentifier =
            "onboarding.safari.callout.activateButton"
        activateButton.addTarget(
            self, action: #selector(activateTapped), for: .touchUpInside)
        glass.contentView.addSubview(activateButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The X position (in this view's coordinates) the arrow points from.
    var arrowAnchorX: CGFloat = 44 {
        didSet { setNeedsLayout() }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        let arrowSide: CGFloat = Self.arrowHeight * 2 / 1.41421
        arrow.bounds = CGRect(x: 0, y: 0, width: arrowSide, height: arrowSide)
        arrow.center = CGPoint(
            x: min(max(arrowAnchorX, 24), bounds.width - 24),
            y: bounds.height)

        let inset: CGFloat = 20
        let width = bounds.width - inset * 2
        iconView.frame = CGRect(x: inset, y: 18, width: 44, height: 44)
        nameLabel.frame = CGRect(
            x: iconView.frame.maxX + 12,
            y: 18,
            width: width - 44 - 12,
            height: 44)
        explainer.frame = CGRect(
            x: inset,
            y: iconView.frame.maxY + 10,
            width: width,
            height: 62)
        let buttonSize = activateButton.sizeThatFits(
            CGSize(width: width, height: 54))
        let buttonWidth = min(width, max(170, buttonSize.width))
        activateButton.frame = CGRect(
            x: (bounds.width - buttonWidth) / 2,
            y: bounds.height - max(50, buttonSize.height) - 16,
            width: buttonWidth,
            height: max(50, buttonSize.height))
    }

    /// The natural height for a given width (the arrow hangs below it).
    static let preferredHeight: CGFloat = 216

    func setActionsEnabled(_ enabled: Bool) {
        activateButton.isUserInteractionEnabled = enabled
    }

    @objc private func activateTapped() {
        activateButton.isUserInteractionEnabled = false
        onActivate?()
    }
}
