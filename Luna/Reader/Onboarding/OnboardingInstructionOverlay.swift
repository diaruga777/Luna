//
//  OnboardingInstructionOverlay.swift
//  Luna
//

import LunaDesignSystem
import UIKit

final class DemoInstructionOverlay: UIView {
    struct Action {
        let title: String
        let image: UIImage?
        let prominent: Bool
        let action: () -> Void
    }

    private let scrim = UIView()
    private let titleLabel = UILabel()
    private let actionStack = UIStackView()
    private let content = UIStackView()
    private var buttons: [UIButton] = []
    private var handlers: [() -> Void] = []
    private var hasAnimatedIn = false
    private var obscuredAccessibilitySiblings: [
        (view: UIView, wasHidden: Bool)
    ] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        // The production card stays mounted behind this setup sheet. Keep
        // VoiceOver and Switch Control inside the sheet so hidden card buttons
        // cannot be activated while onboarding owns the interaction.
        accessibilityViewIsModal = true
        scrim.backgroundColor = UIColor.black.withAlphaComponent(0.76)
        scrim.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrim)

        titleLabel.font = .systemFont(ofSize: 26, weight: .semibold)
        titleLabel.textColor = .white
        titleLabel.textAlignment = .center
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        actionStack.axis = .vertical
        actionStack.alignment = .fill
        actionStack.spacing = 12

        content.addArrangedSubview(titleLabel)
        content.addArrangedSubview(actionStack)
        content.axis = .vertical
        content.spacing = 28
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)

        let topGuide = UILayoutGuide()
        addLayoutGuide(topGuide)

        NSLayoutConstraint.activate([
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            topGuide.topAnchor.constraint(equalTo: topAnchor),
            topGuide.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: AppOnboardingLayout.contentTopRatio),
            content.topAnchor.constraint(equalTo: topGuide.bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 28),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -28),
            content.bottomAnchor.constraint(
                lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor, constant: -24),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func willMove(toSuperview newSuperview: UIView?) {
        if newSuperview !== superview {
            restoreObscuredAccessibilitySiblings()
        }
        super.willMove(toSuperview: newSuperview)
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        guard let superview else { return }
        obscuredAccessibilitySiblings = superview.subviews
            .filter { $0 !== self }
            .map { sibling in
                let state = (view: sibling, wasHidden: sibling.accessibilityElementsHidden)
                sibling.accessibilityElementsHidden = true
                return state
            }
    }

    func configure(title: String?, actions: [Action]) {
        UIView.transition(
            with: titleLabel,
            duration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.18,
            options: [.transitionCrossDissolve, .beginFromCurrentState]
        ) {
            self.titleLabel.text = title
            self.titleLabel.isHidden = title == nil
        }
        buttons.forEach {
            actionStack.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        handlers = actions.map(\.action)
        buttons = actions.enumerated().map { index, action in
            let button = UIButton(type: .system)
            var configuration = GlassStyle.actionButtonConfiguration(
                title: action.title,
                symbol: "circle",
                prominent: action.prominent)
            configuration.image = action.image
            configuration.imagePlacement = .trailing
            button.configuration = configuration
            button.tag = index
            button.addTarget(
                self, action: #selector(actionTapped(_:)), for: .touchUpInside)
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: 52).isActive = true
            button.accessibilityLabel = action.title
            actionStack.addArrangedSubview(button)
            return button
        }
    }

    func animateIn() {
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true

        if UIAccessibility.isReduceMotionEnabled {
            scrim.alpha = 1
            content.alpha = 1
            content.transform = .identity
            return
        }

        scrim.alpha = 0
        content.alpha = 0
        content.transform = CGAffineTransform(
            translationX: 0, y: 10).scaledBy(x: 0.985, y: 0.985)
        UIView.animate(
            withDuration: 0.52,
            delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            self.scrim.alpha = 1
        }
        UIView.animate(
            withDuration: 0.48,
            delay: 0.11,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            self.content.alpha = 1
            self.content.transform = .identity
        }
    }

    @objc private func actionTapped(_ sender: UIButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
    }

    private func restoreObscuredAccessibilitySiblings() {
        for state in obscuredAccessibilitySiblings {
            state.view.accessibilityElementsHidden = state.wasHidden
        }
        obscuredAccessibilitySiblings.removeAll()
    }
}

enum OnboardingSystemIcons {
    static let shortcuts: UIImage? = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 24), format: format
        ).image { context in
            let cg = context.cgContext
            cg.translateBy(x: 12, y: 12)
            cg.rotate(by: .pi / 4)
            drawShortcutTile(
                in: cg, rect: CGRect(x: -7.5, y: -10, width: 15, height: 15),
                colors: [
                    UIColor(red: 1, green: 0.27, blue: 0.58, alpha: 1),
                    UIColor(red: 0.68, green: 0.22, blue: 0.95, alpha: 1),
                ])
            drawShortcutTile(
                in: cg, rect: CGRect(x: -7.5, y: -5, width: 15, height: 15),
                colors: [
                    UIColor(red: 0.14, green: 0.80, blue: 0.78, alpha: 1),
                    UIColor(red: 0.13, green: 0.42, blue: 0.98, alpha: 1),
                ])
        }.withRenderingMode(.alwaysOriginal)
    }()

    static let actionButton: UIImage? = UIImage(
        systemName: "button.programmable",
        withConfiguration: UIImage.SymbolConfiguration(
            pointSize: 15, weight: .semibold))
        ?? UIImage(systemName: "smallcircle.filled.circle")

    private static func drawShortcutTile(
        in context: CGContext, rect: CGRect, colors: [UIColor]
    ) {
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 4).cgPath
        context.saveGState()
        context.addPath(path)
        context.clip()
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: colors.map(\.cgColor) as CFArray,
            locations: [0, 1]) {
            context.drawLinearGradient(
                gradient,
                start: CGPoint(x: rect.minX, y: rect.minY),
                end: CGPoint(x: rect.maxX, y: rect.maxY),
                options: [])
        }
        context.restoreGState()
    }
}
