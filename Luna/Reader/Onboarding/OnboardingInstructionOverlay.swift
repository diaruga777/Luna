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

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
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

    @objc private func actionTapped(_ sender: UIButton) {
        guard handlers.indices.contains(sender.tag) else { return }
        handlers[sender.tag]()
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
