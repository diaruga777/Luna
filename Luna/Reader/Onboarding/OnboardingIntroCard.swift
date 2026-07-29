//
//  OnboardingIntroCard.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingIntroTiming {
    /// The first line is already present when the launch fade clears. Leave it
    /// alone long enough to read before the answer begins revealing.
    static let secondLineDelay: TimeInterval = 1.45
    /// Slow enough that the circle edge can be read as a deliberate top-down
    /// sweep, while each pixel's hot band remains spatially narrow and brief.
    static let secondLineRevealDuration: TimeInterval = 1.55
}

final class OnboardingIntroCardContentViewController: CardContentViewController {
    var onContinue: (() -> Void)?

    private let firstLine: MoonRevealLineView
    private let secondLine: MoonRevealLineView
    private let button = UIButton(type: .system)
    private var didStart = false

    init(firstLine: String, secondLine: String) {
        self.firstLine = MoonRevealLineView(text: firstLine, initiallyRevealed: true)
        self.secondLine = MoonRevealLineView(text: secondLine)
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(firstLine)
        view.addSubview(secondLine)

        button.configuration = GlassStyle.actionButtonConfiguration(
            title: "Show me how",
            symbol: "arrow.right",
            prominent: true)
        // Carry this app's identity into the glass, but keep it a quiet wash
        // rather than the stronger shared prominent-action fill.
        button.configuration?.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.configuration?.imagePlacement = .trailing
        button.accessibilityLabel = "Show me how"
        button.alpha = 0
        button.transform = CGAffineTransform(scaleX: 0.92, y: 0.92)
        button.isUserInteractionEnabled = false
        button.addTarget(self, action: #selector(continueTapped), for: .touchUpInside)
        view.addSubview(button)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let inset: CGFloat = 24
        let lineHeight: CGFloat = 44
        let gap: CGFloat = 3
        let contentTop = AppOnboardingLayout.contentTop(in: view.bounds)
        firstLine.frame = CGRect(
            x: inset, y: contentTop,
            width: view.bounds.width - inset * 2, height: lineHeight)
        secondLine.frame = CGRect(
            x: inset, y: firstLine.frame.maxY + gap,
            width: view.bounds.width - inset * 2, height: lineHeight)
        let buttonSize = button.sizeThatFits(CGSize(
            width: view.bounds.width - 40, height: 60))
        button.frame = CGRect(
            x: (view.bounds.width - max(170, buttonSize.width)) / 2,
            y: view.bounds.height - max(54, buttonSize.height) - 24,
            width: max(170, buttonSize.width),
            height: max(54, buttonSize.height))
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingIntroTiming.secondLineDelay)
        ) { [weak self] in
            guard let self else { return }
            self.secondLine.reveal(
                duration: OnboardingIntroTiming.secondLineRevealDuration
            ) { [weak self] in
                guard let self else { return }
                UIView.animate(
                    withDuration: 0.38,
                    delay: 0.16,
                    options: [.curveEaseOut, .beginFromCurrentState]
                ) {
                    self.button.alpha = 1
                    self.button.transform = .identity
                } completion: { _ in
                    self.button.isUserInteractionEnabled = true
                    UIAccessibility.post(
                        notification: .layoutChanged,
                        argument: self.button)
                }
            }
        }
    }

    @objc private func continueTapped() {
        button.isUserInteractionEnabled = false
        UIView.animate(
            withDuration: 0.16,
            animations: {
                self.button.transform = CGAffineTransform(scaleX: 0.96, y: 0.96)
                self.button.alpha = 0.72
            },
            completion: { [weak self] _ in self?.onContinue?() })
    }
}

final class OnboardingBrowserSeedCardContentViewController: CardContentViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }
}

/// A borderless black circle hides the unrevealed text against the black card.
/// Its exact outer edge also drives four narrow illumination rings, clipped to
/// the glyph alpha: each newly exposed letter pixel becomes a tiny white light
/// source, blooms into its neighbors, then falls rapidly back to normal white
/// as the edge moves away.
final class MoonRevealLineView: UIView {
    private static let edgeFalloff: [(inner: CGFloat, outer: CGFloat, alpha: CGFloat)] = [
        (0, 1.25, 1.00),
        (1.25, 3.00, 0.56),
        (3.00, 5.50, 0.18),
        (5.50, 8.50, 0.045),
    ]

    private let clippedContent = UIView()
    private let finalLabel = UILabel()
    private let illuminationMaskLabel = UILabel()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let bloomLayer = CALayer()
    private let illuminatedGlyphLayer = CALayer()
    private let illuminationRings = CALayer()
    private var didStartReveal = false
    private var initialCircleFrame = CGRect.zero
    private(set) var isFullyRevealed: Bool

    var occluderHasVisibleChrome: Bool {
        moonLayer.borderWidth > 0
            || moonLayer.lineWidth > 0
            || moonLayer.strokeColor != nil
            || moonLayer.shadowOpacity > 0
    }

    var occluderIsFullyOpaque: Bool {
        moonLayer.opacity == 1
            && moonLayer.fillColor?.alpha == 1
            && revealMaskLayer.fillColor?.alpha == 1
    }

    var usesGlyphEdgeIllumination: Bool {
        illuminatedGlyphLayer.mask === illuminationMaskLabel.layer
            && bloomLayer.mask == nil
            && bloomLayer.shadowOpacity == 1
            && illuminationRings.sublayers?.count == Self.edgeFalloff.count
    }

    init(text: String, initiallyRevealed: Bool = false) {
        self.isFullyRevealed = initiallyRevealed
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        clipsToBounds = false
        isAccessibilityElement = initiallyRevealed
        accessibilityLabel = text

        clippedContent.clipsToBounds = true
        clippedContent.isUserInteractionEnabled = false
        addSubview(clippedContent)

        for label in [finalLabel, illuminationMaskLabel] {
            label.text = text
            label.font = .systemFont(ofSize: 25, weight: .semibold)
            label.textColor = .white
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.72
            label.isAccessibilityElement = false
        }
        clippedContent.addSubview(finalLabel)

        guard !initiallyRevealed else { return }

        moonLayer.fillColor = UIColor.black.cgColor
        moonLayer.opacity = 1
        moonLayer.strokeColor = nil
        moonLayer.lineWidth = 0
        moonLayer.shadowOpacity = 0
        clippedContent.layer.addSublayer(moonLayer)

        // The ordinary text is geometrically absent inside the circle. This is
        // stronger than painting black over subpixel-antialiased white glyphs:
        // there is no covered glyph alpha available to bleed through.
        revealMaskLayer.fillColor = UIColor.white.cgColor
        revealMaskLayer.fillRule = .evenOdd
        revealMaskLayer.opacity = 1
        finalLabel.layer.mask = revealMaskLayer

        // Keep the glyph mask on a child and the shadow on its unmasked parent.
        // Masking the shadow-bearing layer itself clips away the very bloom that
        // should illuminate pixels surrounding the hot edge of each letter.
        bloomLayer.shadowColor = UIColor.white.cgColor
        bloomLayer.shadowRadius = 15
        bloomLayer.shadowOpacity = 1
        bloomLayer.shadowOffset = .zero
        illuminatedGlyphLayer.addSublayer(illuminationRings)
        illuminatedGlyphLayer.mask = illuminationMaskLabel.layer
        bloomLayer.addSublayer(illuminatedGlyphLayer)
        layer.addSublayer(bloomLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        clippedContent.frame = bounds
        finalLabel.frame = bounds
        guard !isFullyRevealed, !didStartReveal, bounds.width > 0, bounds.height > 0
        else { return }
        prepareRevealLayers()
    }

    func reveal(duration: TimeInterval, completion: @escaping () -> Void) {
        guard !isFullyRevealed else {
            completion()
            return
        }
        guard !didStartReveal else { return }
        didStartReveal = true
        layoutIfNeeded()
        let initialTop = initialCircleFrame.minY
        let travel = bounds.maxY + 6 - initialTop
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        let transform = CATransform3DMakeTranslation(0, travel, 0)
        let finalCircleFrame = initialCircleFrame.offsetBy(dx: 0, dy: travel)
        let initialRevealPath = revealPath(excluding: initialCircleFrame)
        let finalRevealPath = revealPath(excluding: finalCircleFrame)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.transform = transform
        illuminationRings.transform = transform
        revealMaskLayer.path = finalRevealPath
        CATransaction.commit()

        let moonAnimation = CABasicAnimation(keyPath: "transform")
        moonAnimation.fromValue = CATransform3DIdentity
        moonAnimation.toValue = transform
        moonAnimation.duration = resolvedDuration
        moonAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        moonAnimation.isRemovedOnCompletion = true
        moonAnimation.beginTime = moonLayer.convertTime(
            CACurrentMediaTime(), from: nil)
        moonLayer.add(moonAnimation, forKey: "moonReveal")

        let ringAnimation = moonAnimation.copy() as! CABasicAnimation
        ringAnimation.beginTime = illuminationRings.convertTime(
            CACurrentMediaTime(), from: nil)
        illuminationRings.add(ringAnimation, forKey: "pixelIllumination")

        let revealAnimation = CABasicAnimation(keyPath: "path")
        revealAnimation.fromValue = initialRevealPath
        revealAnimation.toValue = finalRevealPath
        revealAnimation.duration = resolvedDuration
        revealAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealAnimation.isRemovedOnCompletion = true
        revealAnimation.beginTime = revealMaskLayer.convertTime(
            CACurrentMediaTime(), from: nil)
        revealMaskLayer.add(revealAnimation, forKey: "opaqueGlyphReveal")

        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(resolvedDuration)
        ) { [weak self] in
            guard let self else { return }
            self.isFullyRevealed = true
            self.isAccessibilityElement = true
            self.finalLabel.layer.mask = nil
            self.moonLayer.removeFromSuperlayer()
            self.bloomLayer.removeFromSuperlayer()
            completion()
        }
    }

    private func prepareRevealLayers() {
        // A very large circle makes the segment crossing the text nearly
        // horizontal while preserving a real circular distance field.
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        // At the line's extreme left/right the edge begins four points above
        // the glyph cap, ensuring no antialiased text pixel leaks out early.
        let initialTop = 4 - sagitta
        let circleFrame = CGRect(
            x: bounds.midX - radius,
            y: initialTop,
            width: diameter,
            height: diameter)
        initialCircleFrame = circleFrame
        let circlePath = UIBezierPath(ovalIn: circleFrame).cgPath

        moonLayer.frame = bounds
        moonLayer.path = circlePath
        moonLayer.transform = CATransform3DIdentity

        revealMaskLayer.frame = finalLabel.bounds
        revealMaskLayer.path = revealPath(excluding: circleFrame)

        bloomLayer.frame = bounds
        illuminatedGlyphLayer.frame = bounds
        illuminationRings.frame = bounds
        illuminationRings.transform = CATransform3DIdentity
        illuminationMaskLabel.frame = bounds
        illuminationMaskLabel.layer.contentsScale = traitCollection.displayScale

        illuminationRings.sublayers?.forEach { $0.removeFromSuperlayer() }
        for band in Self.edgeFalloff.reversed() {
            let ring = CAShapeLayer()
            let path = UIBezierPath(
                ovalIn: circleFrame.insetBy(dx: -band.outer, dy: -band.outer))
            path.append(UIBezierPath(
                ovalIn: circleFrame.insetBy(dx: -band.inner, dy: -band.inner)))
            path.usesEvenOddFillRule = true
            ring.frame = bounds
            ring.path = path.cgPath
            ring.fillRule = .evenOdd
            ring.fillColor = UIColor.white.withAlphaComponent(band.alpha).cgColor
            ring.strokeColor = nil
            ring.shadowOpacity = 0
            illuminationRings.addSublayer(ring)
        }
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}
