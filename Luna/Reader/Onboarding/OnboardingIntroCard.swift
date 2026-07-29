//
//  OnboardingIntroCard.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingIntroTiming {
    /// Both sentences use the same deliberate top-down lunar sweep. The first
    /// begins the instant `start()` is called — at the launch splash's fade
    /// start — with no settling delay.
    static let lineRevealDuration: TimeInterval = 1.55
    /// A short reading beat keeps the two sentences distinct without making the
    /// second feel like a separate stage.
    static let interLineDelay: TimeInterval = 0.32
}

final class OnboardingIntroCardContentViewController: CardContentViewController {
    var onContinue: (() -> Void)?

    private let firstLine: MoonRevealLineView
    private let secondLine: MoonRevealLineView
    private let supportingLabel = UILabel()
    private let button = UIButton(type: .system)
    private var didStart = false

    init(firstLine: String, secondLine: String, supportingText: String) {
        self.firstLine = MoonRevealLineView(text: firstLine)
        self.secondLine = MoonRevealLineView(text: secondLine)
        self.supportingLabel.text = supportingText
        super.init()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        view.addSubview(firstLine)
        view.addSubview(secondLine)

        supportingLabel.font = .systemFont(ofSize: 17, weight: .medium)
        supportingLabel.textColor = UIColor.white.withAlphaComponent(0.78)
        supportingLabel.textAlignment = .center
        supportingLabel.numberOfLines = 2
        supportingLabel.lineBreakMode = .byWordWrapping
        supportingLabel.alpha = 0
        supportingLabel.isAccessibilityElement = false
        supportingLabel.accessibilityIdentifier = "onboarding.intro.supportingText"
        view.addSubview(supportingLabel)

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
        let supportingHeight: CGFloat = 52
        let availableCenterY = (secondLine.frame.maxY + button.frame.minY) / 2
        supportingLabel.frame = CGRect(
            x: inset,
            y: availableCenterY - supportingHeight / 2,
            width: view.bounds.width - inset * 2,
            height: supportingHeight)
    }

    func start() {
        guard !didStart else { return }
        didStart = true
        view.layoutIfNeeded()
        firstLine.reveal(
            duration: OnboardingIntroTiming.lineRevealDuration
        ) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.asyncAfter(
                deadline: .now() + OnboardingAnimationClock.delay(
                    OnboardingIntroTiming.interLineDelay)
            ) { [weak self] in
                guard let self else { return }
                self.secondLine.reveal(
                    duration: OnboardingIntroTiming.lineRevealDuration
                ) { [weak self] in
                    guard let self else { return }
                    UIView.animate(
                        withDuration: 0.38,
                        delay: 0.16,
                        options: [.curveEaseOut, .beginFromCurrentState]
                    ) {
                        self.supportingLabel.alpha = 1
                        self.button.alpha = 1
                        self.button.transform = .identity
                    } completion: { _ in
                        self.supportingLabel.isAccessibilityElement = true
                        self.button.isUserInteractionEnabled = true
                        UIAccessibility.post(
                            notification: .layoutChanged,
                            argument: self.supportingLabel)
                    }
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

/// A borderless black circle hides the unrevealed text against the black card.
/// Its exact outer edge also drives a raster light pass clipped to the glyph
/// alpha. Every newly exposed antialiased glyph pixel becomes an additive white
/// emitter with stacked near, middle, and wide halos, then cools rapidly back
/// to normal white as the edge moves away.
final class MoonRevealLineView: UIView {
    private let clippedContent = UIView()
    private let finalLabel = UILabel()
    private let illuminationMaskLabel = UILabel()
    private let moonLayer = CAShapeLayer()
    private let revealMaskLayer = CAShapeLayer()
    private let pixelBloomView = GlyphPixelBloomView()
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
        pixelBloomView.usesRasterizedGlyphPixels
            && pixelBloomView.usesStackedAdditiveHalos
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

        // This view owns a padded backing store so the light is not cropped to
        // the label bounds. Its source image is the actual rasterized glyph
        // alpha, not a whole-label or whole-word approximation.
        pixelBloomView.isUserInteractionEnabled = false
        addSubview(pixelBloomView)
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

        pixelBloomView.reveal(
            circleTravel: travel,
            duration: OnboardingAnimationClock.displayLinkDuration(
                resolvedDuration))

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
            self.pixelBloomView.stop()
            self.pixelBloomView.removeFromSuperview()
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

        illuminationMaskLabel.frame = bounds
        illuminationMaskLabel.layoutIfNeeded()

        let padding = GlyphPixelBloomView.renderPadding
        pixelBloomView.frame = bounds.insetBy(dx: -padding, dy: -padding)
        pixelBloomView.configure(
            glyphLabel: illuminationMaskLabel,
            glyphFrame: CGRect(
                x: padding,
                y: padding,
                width: bounds.width,
                height: bounds.height),
            circleFrame: circleFrame.offsetBy(dx: padding, dy: padding),
            scale: traitCollection.displayScale)
    }

    private func revealPath(excluding circleFrame: CGRect) -> CGPath {
        let path = UIBezierPath(rect: bounds)
        path.append(UIBezierPath(ovalIn: circleFrame))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

/// Draws the transient light separately from the ordinary text.
///
/// The emitter is rebuilt at display cadence by intersecting the descending
/// circle's narrow trailing bands with a native-scale raster of the glyphs.
/// Quartz shadows are then applied to that exact alpha image in additive passes.
/// Keeping the padded result in its own view lets the glow illuminate pixels
/// around the letters instead of being clipped back to the text mask.
private final class GlyphPixelBloomView: UIView {
    struct EdgeBand {
        let inner: CGFloat
        let outer: CGFloat
        let alpha: CGFloat
    }

    struct HaloPass {
        let radius: CGFloat
        let alpha: CGFloat
    }

    static let renderPadding: CGFloat = 42

    private static let edgeFalloff = [
        EdgeBand(inner: 0, outer: 1.75, alpha: 1.00),
        EdgeBand(inner: 1.75, outer: 4.00, alpha: 0.72),
        EdgeBand(inner: 4.00, outer: 7.25, alpha: 0.32),
        EdgeBand(inner: 7.25, outer: 10.50, alpha: 0.09),
    ]

    // Several optically additive passes are intentional. A single CALayer
    // shadow reads as soft text; stacked scales produce a clipped white core,
    // a dense local flare that erases legibility, and a broad low-frequency
    // wash like the first visible edge of the sun.
    private static let haloPasses = [
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 30, alpha: 0.72),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 18, alpha: 0.90),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 10, alpha: 1.00),
        HaloPass(radius: 5, alpha: 1.00),
        HaloPass(radius: 2, alpha: 1.00),
    ]

    private var glyphImage: UIImage?
    private var glyphFrame = CGRect.zero
    private var initialCircleFrame = CGRect.zero
    private var circleTravel: CGFloat = 0
    private var progress: CGFloat = 0
    private var revealStartTime: CFTimeInterval = 0
    private var revealDuration: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var emitterRenderer: UIGraphicsImageRenderer?

    var usesRasterizedGlyphPixels: Bool {
        glyphImage != nil && !glyphFrame.isEmpty
    }

    var usesStackedAdditiveHalos: Bool {
        Self.haloPasses.count >= 3
            && Self.haloPasses.first?.radius == 30
            && Self.haloPasses.last?.radius == 2
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    deinit {
        displayLink?.invalidate()
    }

    func configure(
        glyphLabel: UILabel,
        glyphFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat
    ) {
        let glyphFormat = UIGraphicsImageRendererFormat()
        glyphFormat.scale = scale
        glyphFormat.opaque = false
        let glyphRenderer = UIGraphicsImageRenderer(
            size: glyphLabel.bounds.size,
            format: glyphFormat)
        glyphImage = glyphRenderer.image { _ in
            glyphLabel.drawText(in: glyphLabel.bounds)
        }

        self.glyphFrame = glyphFrame
        initialCircleFrame = circleFrame
        progress = 0

        let emitterFormat = UIGraphicsImageRendererFormat()
        emitterFormat.scale = scale
        emitterFormat.opaque = false
        emitterRenderer = UIGraphicsImageRenderer(
            size: bounds.size,
            format: emitterFormat)
        setNeedsDisplay()
    }

    func reveal(circleTravel: CGFloat, duration: CFTimeInterval) {
        stop()
        self.circleTravel = circleTravel
        revealDuration = max(duration, 0.001)
        revealStartTime = CACurrentMediaTime()
        progress = 0
        setNeedsDisplay()

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(drawNextRevealFrame(_:)))
        displayLink.preferredFrameRateRange = CAFrameRateRange(
            minimum: 30,
            maximum: 120,
            preferred: 60)
        displayLink.add(to: .main, forMode: .common)
        self.displayLink = displayLink
    }

    func stop() {
        displayLink?.invalidate()
        displayLink = nil
    }

    override func draw(_ rect: CGRect) {
        guard let emitter = makeEmitterImage(),
              let context = UIGraphicsGetCurrentContext()
        else { return }

        context.saveGState()
        context.setBlendMode(.plusLighter)
        for halo in Self.haloPasses {
            context.saveGState()
            context.setShadow(
                offset: .zero,
                blur: halo.radius,
                color: UIColor.white.withAlphaComponent(halo.alpha).cgColor)
            emitter.draw(in: bounds, blendMode: .plusLighter, alpha: 1)
            context.restoreGState()
        }
        context.restoreGState()
    }

    @objc private func drawNextRevealFrame(_ link: CADisplayLink) {
        let elapsed = link.timestamp - revealStartTime
        progress = min(max(CGFloat(elapsed / revealDuration), 0), 1)
        setNeedsDisplay()
        if progress >= 1 {
            stop()
        }
    }

    private func makeEmitterImage() -> UIImage? {
        guard let glyphImage, let emitterRenderer else { return nil }
        let circleFrame = initialCircleFrame.offsetBy(
            dx: 0,
            dy: circleTravel * progress)

        return emitterRenderer.image { rendererContext in
            let context = rendererContext.cgContext
            for band in Self.edgeFalloff {
                context.saveGState()
                let ring = UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.outer,
                        dy: -band.outer))
                ring.append(UIBezierPath(
                    ovalIn: circleFrame.insetBy(
                        dx: -band.inner,
                        dy: -band.inner)))
                ring.usesEvenOddFillRule = true
                context.addPath(ring.cgPath)
                context.clip(using: .evenOdd)
                glyphImage.draw(
                    in: glyphFrame,
                    blendMode: .normal,
                    alpha: band.alpha)
                context.restoreGState()
            }
        }
    }
}
