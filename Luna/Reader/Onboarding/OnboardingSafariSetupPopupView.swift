//
//  OnboardingSafariSetupPopupView.swift
//  Luna
//

import LunaDesignSystem
import LunaModels
import UIKit

/// The ONE ending every Safari lesson shares now, in all four apps: a minimal
/// card — "Set up in Safari" and "Skip", nothing else — over a light scrim,
/// with whatever lesson raised it still visible (and, after a short freeze,
/// still looping) underneath.
///
/// Step-by-step instructions used to live wherever the lesson ended: inline at
/// the bottom of the `luna.app` explainer page, grown into the Downloader's
/// video panel, or on `OnboardingSafariSetupCardView` over the price lesson's
/// product page. All three are gone — that copy now lives on the hosted setup
/// web page the prominent button opens — and every lesson ends on this one
/// popup instead.
///
/// Visually it borrows two things wholesale: the night-surface card with a
/// static launch `EclipseCoronaView` worn as its border, exactly like
/// `OnboardingSafariSetupCardView` and `DemoInstructionOverlay`'s retired
/// `.eclipseCard` style did, and the Skip button's own styling from the
/// retired `OnboardingSafariActionsView` (plain configuration, white @ 0.7,
/// 16pt medium).
final class OnboardingSafariSetupPopupView: UIView {
    /// The alpha of the FULL-SCREEN scrim behind the card. Deliberately
    /// light — every host now freezes the lesson that raised this popup and
    /// then loops it forever underneath, so there is always something back
    /// there worth keeping legible. Where a lesson already carries its own
    /// dimming (the price lesson's 70% spotlight scrim), the two stack: both
    /// stay visible, darker where they overlap.
    ///
    /// The scrim itself is NOT a subview of this view — it is a separate
    /// `SafariSetupScrimView` that `AppOnboardingViewController
    /// .showSafariSetupPopup()` mounts directly on the window, BELOW this
    /// view, entirely independent of this view's own layout. That is
    /// deliberate, for two reasons: this view's card and its border corona
    /// rebuild themselves on geometry changes (`layoutSubviews` below), and a
    /// scrim living inside the same view as code that removes-and-reinserts
    /// subviews is one more thing that code could disturb; and the popup
    /// itself is raised from whichever `SafariReplicaViewController` happens
    /// to be on screen when the lesson reaches its setup offer, while central
    /// Luna's cycle keeps swapping which sibling that is underneath. A scrim
    /// (and popup) owned by ONE of those swapped-out replicas is owned by an
    /// object that does not outlive the swap; owned by the controller that
    /// runs the swap, both outlive every one of them.
    static let scrimAlpha: CGFloat = 0.30
    static let cornerRadius: CGFloat = 26
    private static let horizontalInset: CGFloat = 26
    private static let verticalInset: CGFloat = 24
    private static let interActionGap: CGFloat = 16
    private static let pulseKey = "onboarding.safariSetupPopup.pulse"

    var onActivate: (() -> Void)?
    var onSkip: (() -> Void)?

    private let card = UIView()
    /// The card's own border corona. Sits behind `card` as a sibling in this
    /// (unclipped) full-bleed view rather than inside it, the same arrangement
    /// `DemoInstructionOverlay` and `OnboardingSafariSetupCardView` use.
    private var corona: EclipseCoronaView?
    private let activateButton: OnboardingSafariSetupActionButton
    /// The tight corona wrapped directly around the activate button's own
    /// capsule — the actionable control, made unmistakable, distinct from the
    /// card's own decorative border.
    private var activateCorona: EclipseCoronaView?
    private let skipButton = UIButton(type: .system)
    private var isPulsing = false
    private var hasAnimatedIn = false

    override init(frame: CGRect) {
        activateButton = OnboardingSafariSetupActionButton(
            title: OnboardingStrings.Safari.setUpInSafari.value())
        super.init(frame: frame)
        backgroundColor = .clear
        // The production content stays mounted (and, once the freeze ends,
        // running) behind this popup. Keep VoiceOver and Switch Control inside
        // it while onboarding owns the interaction.
        accessibilityViewIsModal = true
        accessibilityIdentifier = OnboardingStrings.Accessibility.safariActions.value()

        card.backgroundColor = LunaColors.background
        card.layer.cornerRadius = Self.cornerRadius
        card.layer.cornerCurve = .continuous
        card.clipsToBounds = true
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        activateButton.accessibilityLabel = OnboardingStrings.Safari.setUpInSafari.value()
        activateButton.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariActivate.value()
        activateButton.addTarget(
            self, action: #selector(activateTapped), for: .touchUpInside)
        activateButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(activateButton)

        var skipConfiguration = UIButton.Configuration.plain()
        skipConfiguration.title = OnboardingStrings.Safari.skip.value()
        skipConfiguration.baseForegroundColor =
            UIColor.white.withAlphaComponent(0.7)
        skipConfiguration.contentInsets = NSDirectionalEdgeInsets(
            top: 8, leading: 14, bottom: 8, trailing: 14)
        skipConfiguration.titleTextAttributesTransformer =
            UIConfigurationTextAttributesTransformer { incoming in
                var outgoing = incoming
                outgoing.font = .systemFont(ofSize: 16, weight: .medium)
                return outgoing
            }
        skipButton.configuration = skipConfiguration
        skipButton.accessibilityLabel = OnboardingStrings.Safari.skip.value()
        skipButton.accessibilityIdentifier =
            OnboardingStrings.Accessibility.safariSkip.value()
        skipButton.addTarget(
            self, action: #selector(skipTapped), for: .touchUpInside)
        skipButton.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(skipButton)

        let topGuide = UILayoutGuide()
        addLayoutGuide(topGuide)

        NSLayoutConstraint.activate([
            topGuide.topAnchor.constraint(equalTo: topAnchor),
            topGuide.heightAnchor.constraint(
                equalTo: heightAnchor,
                multiplier: AppOnboardingLayout.contentTopRatio),

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

            activateButton.topAnchor.constraint(
                equalTo: card.topAnchor, constant: Self.verticalInset),
            activateButton.leadingAnchor.constraint(
                equalTo: card.leadingAnchor, constant: Self.horizontalInset),
            activateButton.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Self.horizontalInset),
            activateButton.heightAnchor.constraint(
                equalToConstant: OnboardingSafariSetupActionButton.height),
            activateButton.widthAnchor.constraint(
                greaterThanOrEqualToConstant:
                    OnboardingSafariSetupActionButton.minimumWidth),

            skipButton.topAnchor.constraint(
                equalTo: activateButton.bottomAnchor,
                constant: Self.interActionGap),
            skipButton.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            skipButton.bottomAnchor.constraint(
                equalTo: card.bottomAnchor, constant: -Self.verticalInset),
        ])

        setActionsEnabled(true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard card.bounds.width > 0, card.bounds.height > 0 else { return }
        if corona?.bounds.size != card.bounds.size {
            corona?.removeFromSuperview()
            let halo = EclipseCoronaView(
                bodySize: card.bounds.size,
                cornerRadius: Self.cornerRadius,
                tint: LunaSurfacePalette.atmosphereTint)
            // Already on screen: a resize (a rotation, an iPad Split View
            // change) must not make the border pop back in from nothing.
            halo.alpha = hasAnimatedIn ? 1 : 0
            insertSubview(halo, belowSubview: card)
            corona = halo
        }
        // `corona` is a SIBLING of `card` in this view (unclipped, so the
        // glow can throw light past card's own edge) rather than a child of
        // it, so it needs card's FRAME — its position within their shared
        // superview — not card's bounds, which is always zero-origin and
        // would pin the halo to this view's own top-left corner regardless
        // of where the card actually sits.
        corona?.frame = card.frame
        layOutActivateCorona()
    }

    /// The corona is the card's own, not the activate button's — see
    /// `activateCorona` above for that one. Rebuilt only when the button's own
    /// geometry changes.
    private func layOutActivateCorona() {
        let frame = card.convert(activateButton.bounds, from: activateButton)
        guard frame.width > 0, frame.height > 0 else { return }
        if activateCorona?.bounds.size != frame.size {
            activateCorona?.removeFromSuperview()
            let halo = EclipseCoronaView(
                bodySize: frame.size,
                cornerRadius: frame.height / 2,
                tint: LunaSurfacePalette.atmosphereTint)
            halo.alpha = hasAnimatedIn ? 1 : 0
            card.insertSubview(halo, belowSubview: activateButton)
            activateCorona = halo
            // A resize rebuilds the view, so the breath it replaces has to be
            // re-applied — a fresh layer carries no animation of its own. See
            // the pulse invariants below.
            applyPulse()
        }
        activateCorona?.frame = frame
    }

    // MARK: - Presentation

    /// - Parameter externalScrim: the host's own full-screen, 30%-black
    ///   scrim (see the type doc above) — faded in on the SAME animation as
    ///   this card, so the two arrive as one visual beat even though the
    ///   scrim is not this view's own subview.
    func present(fadingInAlongside externalScrim: UIView? = nil) {
        guard !hasAnimatedIn else { return }
        hasAnimatedIn = true
        guard !UIAccessibility.isReduceMotionEnabled else {
            externalScrim?.alpha = 1
            card.alpha = 1
            corona?.alpha = 1
            activateCorona?.alpha = OnboardingAttentionPulse.reduceMotionGlowAlpha
            return
        }
        externalScrim?.alpha = 0
        card.alpha = 0
        corona?.alpha = 0
        activateCorona?.alpha = 0
        card.transform = CGAffineTransform(translationX: 0, y: 10)
            .scaledBy(x: 0.985, y: 0.985)
        UIView.animate(
            withDuration: 0.42, delay: 0,
            options: [.curveEaseInOut, .beginFromCurrentState]
        ) {
            externalScrim?.alpha = 1
            self.card.alpha = 1
            self.corona?.alpha = 1
            self.activateCorona?.alpha = 1
            self.card.transform = .identity
        } completion: { [weak self] _ in
            self?.beginPulse()
        }
    }

    func setActionsEnabled(_ enabled: Bool) {
        activateButton.isUserInteractionEnabled = enabled
        skipButton.isUserInteractionEnabled = enabled
    }

    /// The return leg from real Safari with nothing to show for it: the
    /// buttons come back live, and the plea starts breathing again.
    func reactivate() {
        setActionsEnabled(true)
        beginPulse()
    }

    // MARK: - The pulse
    //
    // The same three invariants `OnboardingSafariPageView` and
    // `OnboardingSafariSetupCardView` kept, now in one place: (a) never
    // guarded on already-pulsing — backgrounding strips every CA animation off
    // a layer, and the Safari hop backgrounds the app, so the return leg has
    // to be able to put the breath back rather than trust its own flag; (b)
    // the corona scales WITH the button, sharing its centre, and its glow
    // troughs at `litCoronaTroughAlpha` rather than starting from zero — it is
    // already lit; (c) a corona rebuild re-applies the pulse (`applyPulse`
    // above), since the fresh layer starts with none.

    private func beginPulse() {
        guard !UIAccessibility.isReduceMotionEnabled else {
            activateCorona?.alpha = OnboardingAttentionPulse.reduceMotionGlowAlpha
            return
        }
        isPulsing = true
        applyPulse()
    }

    private func applyPulse() {
        guard isPulsing else { return }
        activateButton.layer.add(
            OnboardingAttentionPulse.scale(), forKey: Self.pulseKey)
        guard let activateCorona else { return }
        activateCorona.layer.add(
            OnboardingAttentionPulse.scale(),
            forKey: "\(Self.pulseKey).coronaScale")
        activateCorona.layer.add(
            OnboardingAttentionPulse.glow(
                from: OnboardingAttentionPulse.litCoronaTroughAlpha),
            forKey: "\(Self.pulseKey).coronaGlow")
    }

    private func endPulse() {
        isPulsing = false
        activateButton.layer.removeAnimation(forKey: Self.pulseKey)
        activateCorona?.layer.removeAnimation(
            forKey: "\(Self.pulseKey).coronaScale")
        activateCorona?.layer.removeAnimation(
            forKey: "\(Self.pulseKey).coronaGlow")
    }

    @objc private func activateTapped() {
        endPulse()
        setActionsEnabled(false)
        onActivate?()
    }

    @objc private func skipTapped() {
        endPulse()
        setActionsEnabled(false)
        onSkip?()
    }

    #if DEBUG
    /// The flag, not the animations: CoreAnimation drops an animation off a
    /// backgrounded layer, so only this survives a test that spins the run
    /// loop.
    var isPulsingForTesting: Bool { isPulsing }
    var activateButtonForTesting: UIButton { activateButton }
    var skipButtonForTesting: UIButton { skipButton }
    #endif
}

/// The popup's full-screen 30%-black scrim. A distinct, named type (rather
/// than a bare `UIView`) so anything that needs to find or count it — the
/// host's own teardown, a test — can do so precisely instead of guessing at a
/// plain view by its background color. Exactly one is ever mounted, and it is
/// owned directly by `AppOnboardingViewController.showSafariSetupPopup()`,
/// for the same reason that controller owns the popup itself now rather than
/// whichever `SafariReplicaViewController` happened to raise it — see this
/// file's `OnboardingSafariSetupPopupView.scrimAlpha` doc comment above.
final class SafariSetupScrimView: UIView {}

/// The popup's one prominent action: a hand-drawn full-colour Safari-style
/// compass on the LEFT (never Apple's Safari icon asset, never the monochrome
/// `safari` SF Symbol — this button is Luna's own artwork), the label, and the
/// `arrow.up.forward.square` glyph on the RIGHT that says "this leaves the
/// app". `GlassStyle.actionButtonConfiguration` gives it the same glass
/// capsule every other prominent action button wears; the trailing glyph is a
/// plain overlaid image view rather than a second `UIButton.Configuration`
/// image, since a configuration can only place one image, and this button
/// needs two — one on each side, in different roles.
final class OnboardingSafariSetupActionButton: UIButton {
    static let height: CGFloat = 52
    static let minimumWidth: CGFloat = 214
    private static let compassSide: CGFloat = 22
    private static let trailingGlyphSide: CGFloat = 15
    private static let trailingGlyphTrailingInset: CGFloat = 16

    private let trailingGlyph = UIImageView(image: UIImage(
        systemName: "arrow.up.forward.square",
        withConfiguration: UIImage.SymbolConfiguration(
            pointSize: 15, weight: .semibold)))

    init(title: String) {
        super.init(frame: .zero)
        var config = GlassStyle.actionButtonConfiguration(
            title: title, symbol: "safari.fill", prominent: true)
        config.image = OnboardingSafariCompassGlyph.image(side: Self.compassSide)
        config.imagePlacement = .leading
        config.imagePadding = 10
        // Room on the right for `trailingGlyph`, which this configuration
        // cannot itself carry.
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 13, leading: 20, bottom: 13,
            trailing: Self.trailingGlyphTrailingInset * 2
                + Self.trailingGlyphSide)
        configuration = config

        trailingGlyph.tintColor = .white
        trailingGlyph.isUserInteractionEnabled = false
        addSubview(trailingGlyph)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        trailingGlyph.frame = CGRect(
            x: bounds.width - Self.trailingGlyphSide
                - Self.trailingGlyphTrailingInset,
            y: ((bounds.height - Self.trailingGlyphSide) / 2).rounded(),
            width: Self.trailingGlyphSide,
            height: Self.trailingGlyphSide)
    }
}

/// A hand-drawn compass dial, full colour: a white-to-blue radial dial face, a
/// ring of tick marks, and a red/white needle pointing northeast (45°) — never
/// Apple's Safari icon asset and never the monochrome `safari` SF Symbol.
enum OnboardingSafariCompassGlyph {
    static func image(side: CGFloat, scale: CGFloat = 3) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        return UIGraphicsImageRenderer(
            size: CGSize(width: side, height: side), format: format
        ).image { context in
            let cg = context.cgContext
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
                .insetBy(dx: 0.5, dy: 0.5)
            let center = CGPoint(x: side / 2, y: side / 2)
            let radius = rect.width / 2

            cg.saveGState()
            UIBezierPath(ovalIn: rect).addClip()
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(),
                colors: [
                    UIColor.white.cgColor,
                    UIColor(red: 0.35, green: 0.62, blue: 0.98, alpha: 1).cgColor,
                ] as CFArray,
                locations: [0, 1]) {
                cg.drawRadialGradient(
                    gradient,
                    startCenter: center, startRadius: 0,
                    endCenter: center, endRadius: radius,
                    options: [])
            }
            cg.restoreGState()

            let rim = UIBezierPath(ovalIn: rect)
            UIColor.white.withAlphaComponent(0.9).setStroke()
            rim.lineWidth = 1
            rim.stroke()

            UIColor(white: 0.25, alpha: 0.55).setStroke()
            for index in 0..<12 {
                let angle = CGFloat(index) * (.pi / 6)
                let isCardinal = index.isMultiple(of: 3)
                let tickLength: CGFloat = isCardinal ? 3.2 : 1.8
                let outer = CGPoint(
                    x: center.x + cos(angle) * (radius - 0.5),
                    y: center.y + sin(angle) * (radius - 0.5))
                let inner = CGPoint(
                    x: center.x + cos(angle) * (radius - tickLength),
                    y: center.y + sin(angle) * (radius - tickLength))
                let tick = UIBezierPath()
                tick.move(to: outer)
                tick.addLine(to: inner)
                tick.lineWidth = isCardinal ? 0.9 : 0.6
                tick.stroke()
            }

            // The needle: northeast (45°) in screen coordinates is up-and-right,
            // i.e. angle -π/4. Red half points at the heading; white half is
            // its tail.
            let needleAngle = -CGFloat.pi / 4
            let needleLength = radius * 0.72
            let tip = CGPoint(
                x: center.x + cos(needleAngle) * needleLength,
                y: center.y + sin(needleAngle) * needleLength)
            let tail = CGPoint(
                x: center.x - cos(needleAngle) * needleLength,
                y: center.y - sin(needleAngle) * needleLength)
            let perpendicular = CGPoint(
                x: -sin(needleAngle) * 1.6, y: cos(needleAngle) * 1.6)

            let redHalf = UIBezierPath()
            redHalf.move(to: CGPoint(
                x: center.x + perpendicular.x, y: center.y + perpendicular.y))
            redHalf.addLine(to: tip)
            redHalf.addLine(to: CGPoint(
                x: center.x - perpendicular.x, y: center.y - perpendicular.y))
            redHalf.close()
            UIColor.systemRed.setFill()
            redHalf.fill()

            let whiteHalf = UIBezierPath()
            whiteHalf.move(to: CGPoint(
                x: center.x + perpendicular.x, y: center.y + perpendicular.y))
            whiteHalf.addLine(to: tail)
            whiteHalf.addLine(to: CGPoint(
                x: center.x - perpendicular.x, y: center.y - perpendicular.y))
            whiteHalf.close()
            UIColor.white.setFill()
            whiteHalf.fill()

            let pinSide: CGFloat = 2.2
            let pin = UIBezierPath(ovalIn: CGRect(
                x: center.x - pinSide / 2, y: center.y - pinSide / 2,
                width: pinSide, height: pinSide))
            UIColor(white: 0.2, alpha: 1).setFill()
            pin.fill()
        }.withRenderingMode(.alwaysOriginal)
    }
}
