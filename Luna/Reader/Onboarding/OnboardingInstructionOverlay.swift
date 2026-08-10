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

    /// How the instructions sit over the lesson they interrupt.
    enum Style {
        /// A heavy scrim with the sentence and its buttons standing on it. What
        /// every ask that arrives over a FINISHED demonstration uses: there is
        /// nothing behind it left to watch.
        case plain
        /// A card wearing the launch eclipse's corona as its border, over a
        /// scrim light enough to keep what is underneath legible. Central Luna's
        /// Safari ask uses it, because its three sibling lessons go on replaying
        /// beneath the popover rather than stopping under it.
        case eclipseCard

        var scrimAlpha: CGFloat {
            switch self {
            case .plain: return 0.76
            case .eclipseCard: return 0.42
            }
        }
    }

    /// The card's own geometry, matching the setup card the price and video
    /// lessons end on (`OnboardingSafariSetupCardView`).
    private static let cardCornerRadius: CGFloat = 26
    private static let cardHorizontalInset: CGFloat = 24
    private static let cardVerticalInset: CGFloat = 26

    private let style: Style
    private let scrim = UIView()
    private let titleLabel = UILabel()
    private let actionStack = UIStackView()
    private let content = UIStackView()
    /// The card and its corona, in `.eclipseCard` only: the corona overhangs the
    /// body, so the two travel together inside a container that does not clip.
    private let card = UIView()
    private let cardBody = UIView()
    private var corona: EclipseCoronaView?
    private var buttons: [UIButton] = []
    private var handlers: [() -> Void] = []
    private var hasAnimatedIn = false
    private var obscuredAccessibilitySiblings: [
        (view: UIView, wasHidden: Bool)
    ] = []

    /// What animates in and what a fade acts on: the card in `.eclipseCard`,
    /// the bare stack otherwise.
    private var presentedContent: UIView {
        style == .eclipseCard ? card : content
    }

    init(style: Style = .plain) {
        self.style = style
        super.init(frame: .zero)
        backgroundColor = .clear
        // The production card stays mounted behind this setup sheet. Keep
        // VoiceOver and Switch Control inside the sheet so hidden card buttons
        // cannot be activated while onboarding owns the interaction.
        accessibilityViewIsModal = true
        scrim.backgroundColor = UIColor.black.withAlphaComponent(style.scrimAlpha)
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

        let topGuide = UILayoutGuide()
        addLayoutGuide(topGuide)

        var constraints: [NSLayoutConstraint] = [
            scrim.topAnchor.constraint(equalTo: topAnchor),
            scrim.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrim.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrim.bottomAnchor.constraint(equalTo: bottomAnchor),
            topGuide.topAnchor.constraint(equalTo: topAnchor),
            topGuide.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: AppOnboardingLayout.contentTopRatio),
        ]

        switch style {
        case .plain:
            addSubview(content)
            constraints += [
                content.topAnchor.constraint(equalTo: topGuide.bottomAnchor),
                content.centerXAnchor.constraint(equalTo: centerXAnchor),
                content.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor, constant: 28),
                content.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -28),
                // The instructions are one 26pt sentence and a stack of buttons.
                // Stretched across an iPad they read as a title bar with two
                // banners under it, not as a step to follow.
                content.widthAnchor.constraint(
                    lessThanOrEqualToConstant: LunaLayout.readableWidth),
                content.bottomAnchor.constraint(
                    lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor,
                    constant: -24),
            ]
        case .eclipseCard:
            card.translatesAutoresizingMaskIntoConstraints = false
            // The corona throws light past the body it borders, so nothing in
            // this container may clip.
            card.clipsToBounds = false
            addSubview(card)
            cardBody.backgroundColor = LunaColors.background
            cardBody.layer.cornerRadius = Self.cardCornerRadius
            cardBody.layer.cornerCurve = .continuous
            cardBody.clipsToBounds = true
            cardBody.translatesAutoresizingMaskIntoConstraints = false
            card.addSubview(cardBody)
            cardBody.addSubview(content)
            constraints += [
                cardBody.topAnchor.constraint(equalTo: card.topAnchor),
                cardBody.leadingAnchor.constraint(equalTo: card.leadingAnchor),
                cardBody.trailingAnchor.constraint(equalTo: card.trailingAnchor),
                cardBody.bottomAnchor.constraint(equalTo: card.bottomAnchor),
                content.topAnchor.constraint(
                    equalTo: cardBody.topAnchor,
                    constant: Self.cardVerticalInset),
                content.bottomAnchor.constraint(
                    equalTo: cardBody.bottomAnchor,
                    constant: -Self.cardVerticalInset),
                content.leadingAnchor.constraint(
                    equalTo: cardBody.leadingAnchor,
                    constant: Self.cardHorizontalInset),
                content.trailingAnchor.constraint(
                    equalTo: cardBody.trailingAnchor,
                    constant: -Self.cardHorizontalInset),
                card.topAnchor.constraint(equalTo: topGuide.bottomAnchor),
                card.centerXAnchor.constraint(equalTo: centerXAnchor),
                card.leadingAnchor.constraint(
                    greaterThanOrEqualTo: leadingAnchor, constant: 28),
                card.trailingAnchor.constraint(
                    lessThanOrEqualTo: trailingAnchor, constant: -28),
                card.widthAnchor.constraint(
                    lessThanOrEqualToConstant: LunaLayout.readableWidth),
                card.bottomAnchor.constraint(
                    lessThanOrEqualTo: safeAreaLayoutGuide.bottomAnchor,
                    constant: -24),
            ]
        }

        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The corona is the card's border, so it takes the card's own geometry and
    /// sits directly behind it — rebuilt only when that geometry changes, since
    /// each build rasterises the light.
    override func layoutSubviews() {
        super.layoutSubviews()
        guard style == .eclipseCard,
              card.bounds.width > 0,
              card.bounds.height > 0
        else { return }
        if corona?.bounds.size != card.bounds.size {
            corona?.removeFromSuperview()
            let halo = EclipseCoronaView(
                bodySize: card.bounds.size,
                cornerRadius: Self.cardCornerRadius,
                tint: LunaSurfacePalette.atmosphereTint)
            card.insertSubview(halo, belowSubview: cardBody)
            corona = halo
        }
        corona?.frame = card.bounds
    }

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

        let presented = presentedContent
        if UIAccessibility.isReduceMotionEnabled {
            scrim.alpha = 1
            presented.alpha = 1
            presented.transform = .identity
            return
        }

        scrim.alpha = 0
        presented.alpha = 0
        presented.transform = CGAffineTransform(
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
            presented.alpha = 1
            presented.transform = .identity
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
    /// Apple's actual Shortcuts app icon (bundled PNG), rounded to the app-icon
    /// squircle at UI size. Falls back to the drawn glyph if the resource is
    /// ever missing.
    static let shortcutsAppIcon: UIImage? = {
        guard let path = Bundle.main.path(
            forResource: "ShortcutsAppIcon", ofType: "png"),
            let source = UIImage(contentsOfFile: path)
        else { return shortcuts }
        let side: CGFloat = 24
        let format = UIGraphicsImageRendererFormat()
        format.scale = 3
        format.opaque = false
        let rect = CGRect(x: 0, y: 0, width: side, height: side)
        return UIGraphicsImageRenderer(
            size: rect.size, format: format
        ).image { _ in
            UIBezierPath(
                roundedRect: rect,
                cornerRadius: side * 0.225).addClip()
            source.draw(in: rect)
        }.withRenderingMode(.alwaysOriginal)
    }()

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
