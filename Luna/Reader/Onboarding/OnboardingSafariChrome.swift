//
//  OnboardingSafariChrome.swift
//  Luna
//

import LunaDesignSystem
import UIKit

final class SafariBottomBar: UIView {
    static let chromeHeight: CGFloat = 58

    private let backdrop = UIVisualEffectView(
        effect: UIBlurEffect(style: .systemThinMaterialLight))
    private let backForward = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let address = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let more = UIVisualEffectView(effect: GlassStyle.barEffect())
    private let hostLabel = UILabel()
    private let urlHighlight = OnboardingURLHighlightView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear

        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.alpha = 0.78
        addSubview(backdrop)

        for glass in [backForward, address, more] {
            glass.translatesAutoresizingMaskIntoConstraints = false
            if #available(iOS 26.0, *) {
                glass.cornerConfiguration = .capsule()
            } else {
                glass.layer.cornerRadius = 23
                glass.layer.cornerCurve = .continuous
                glass.clipsToBounds = true
            }
            addSubview(glass)
        }

        let back = icon("chevron.backward", alpha: 0.32)
        let forward = icon("chevron.forward", alpha: 0.16)
        let nav = UIStackView(arrangedSubviews: [back, forward])
        nav.axis = .horizontal
        nav.alignment = .center
        nav.distribution = .fillEqually
        nav.translatesAutoresizingMaskIntoConstraints = false
        backForward.contentView.addSubview(nav)

        let page = icon("text.justify.leading", alpha: 0.86)
        hostLabel.text = "luna.app"
        hostLabel.font = .systemFont(ofSize: 16, weight: .semibold)
        hostLabel.textColor = UIColor(white: 0.10, alpha: 1)
        hostLabel.textAlignment = .center
        hostLabel.adjustsFontSizeToFitWidth = true
        hostLabel.minimumScaleFactor = 0.72
        let reload = icon("arrow.clockwise", alpha: 0.82)
        let addressStack = UIStackView(arrangedSubviews: [page, hostLabel, reload])
        addressStack.axis = .horizontal
        addressStack.alignment = .center
        addressStack.spacing = 9
        addressStack.translatesAutoresizingMaskIntoConstraints = false
        urlHighlight.translatesAutoresizingMaskIntoConstraints = false
        address.contentView.addSubview(urlHighlight)
        address.contentView.addSubview(addressStack)
        page.widthAnchor.constraint(equalToConstant: 21).isActive = true
        reload.widthAnchor.constraint(equalToConstant: 21).isActive = true

        let ellipsis = icon("ellipsis", alpha: 0.9)
        ellipsis.translatesAutoresizingMaskIntoConstraints = false
        more.contentView.addSubview(ellipsis)

        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -12),
            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),
            backForward.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 30),
            backForward.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            backForward.widthAnchor.constraint(equalToConstant: 76),
            backForward.heightAnchor.constraint(equalToConstant: 46),
            address.leadingAnchor.constraint(equalTo: backForward.trailingAnchor, constant: 8),
            address.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            address.heightAnchor.constraint(equalToConstant: 46),
            more.leadingAnchor.constraint(equalTo: address.trailingAnchor, constant: 8),
            more.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -30),
            more.topAnchor.constraint(equalTo: topAnchor, constant: 7),
            more.widthAnchor.constraint(equalToConstant: 46),
            more.heightAnchor.constraint(equalToConstant: 46),
            nav.topAnchor.constraint(equalTo: backForward.contentView.topAnchor),
            nav.leadingAnchor.constraint(
                equalTo: backForward.contentView.leadingAnchor, constant: 4),
            nav.trailingAnchor.constraint(
                equalTo: backForward.contentView.trailingAnchor, constant: -4),
            nav.bottomAnchor.constraint(equalTo: backForward.contentView.bottomAnchor),
            addressStack.topAnchor.constraint(equalTo: address.contentView.topAnchor),
            addressStack.leadingAnchor.constraint(
                equalTo: address.contentView.leadingAnchor, constant: 13),
            addressStack.trailingAnchor.constraint(
                equalTo: address.contentView.trailingAnchor, constant: -13),
            addressStack.bottomAnchor.constraint(equalTo: address.contentView.bottomAnchor),
            urlHighlight.topAnchor.constraint(equalTo: address.contentView.topAnchor),
            urlHighlight.leadingAnchor.constraint(equalTo: address.contentView.leadingAnchor),
            urlHighlight.trailingAnchor.constraint(equalTo: address.contentView.trailingAnchor),
            urlHighlight.bottomAnchor.constraint(equalTo: address.contentView.bottomAnchor),
            ellipsis.centerXAnchor.constraint(equalTo: more.contentView.centerXAnchor),
            ellipsis.centerYAnchor.constraint(equalTo: more.contentView.centerYAnchor),
            ellipsis.widthAnchor.constraint(equalToConstant: 24),
            ellipsis.heightAnchor.constraint(equalToConstant: 24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func setURL(_ urlString: String, displayedHost host: String) {
        accessibilityIdentifier = "onboarding.safari.urlBar"
        accessibilityValue = urlString
        UIView.transition(
            with: hostLabel,
            duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.hostLabel.text = host
        }
    }

    func setURLHighlighted(_ highlighted: Bool) {
        urlHighlight.setHighlighted(highlighted)
    }

    func animateURLBarZoom(completion: @escaping () -> Void) {
        guard !UIAccessibility.isReduceMotionEnabled else {
            completion()
            return
        }
        address.layer.removeAllAnimations()
        UIView.animate(
            withDuration: 0.28,
            delay: 0,
            usingSpringWithDamping: 0.72,
            initialSpringVelocity: 0.3,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.address.transform = CGAffineTransform(scaleX: 1.12, y: 1.12)
            self.backForward.alpha = 0.48
            self.more.alpha = 0.48
        } completion: { _ in
            UIView.animate(
                withDuration: 0.24,
                delay: 0.06,
                options: [.curveEaseInOut, .beginFromCurrentState]
            ) {
                self.address.transform = .identity
                self.backForward.alpha = 1
                self.more.alpha = 1
            } completion: { _ in
                completion()
            }
        }
    }

    var isURLHighlighted: Bool { urlHighlight.isHighlighted }

    var highlightedURLRegion: OnboardingHighlightedLinkRegion {
        OnboardingHighlightedLinkRegion(
            frame: address.frame,
            cornerRadius: address.bounds.height / 2)
    }

    private func icon(_ symbol: String, alpha: CGFloat) -> UIImageView {
        let view = UIImageView(image: UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: 15, weight: .semibold)))
        view.tintColor = UIColor(white: 0.06, alpha: alpha)
        view.contentMode = .center
        return view
    }
}
