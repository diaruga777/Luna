//
//  OnboardingIntroCard.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum OnboardingAppIcon {
    static func image(bundle: Bundle = .main) -> UIImage? {
        let icons = bundle.object(forInfoDictionaryKey: "CFBundleIcons")
            as? [String: Any]
        let primary = icons?["CFBundlePrimaryIcon"] as? [String: Any]
        let iconFiles = primary?["CFBundleIconFiles"] as? [String] ?? []
        for name in iconFiles.reversed() {
            if let image = UIImage(named: name, in: bundle, compatibleWith: nil) {
                return image
            }
            guard let resources = bundle.resourceURL,
                  let entries = try? FileManager.default.contentsOfDirectory(
                    at: resources,
                    includingPropertiesForKeys: nil)
            else { continue }
            let candidates = entries.filter {
                $0.pathExtension == "png"
                    && $0.deletingPathExtension().lastPathComponent.hasPrefix(name)
            }
            if let path = candidates.first?.path,
               let image = UIImage(contentsOfFile: path)
            {
                return image
            }
        }
        return nil
    }
}

enum OnboardingIntroTiming {
    /// A brief settling beat after the splash starts its (near-instant) fade —
    /// enough to separate the reveal from the launch itself while still
    /// reading as immediate.
    static let firstLineDelay: TimeInterval = 0.15
    /// Both sentences use the same deliberate top-down lunar sweep.
    static let lineRevealDuration: TimeInterval = 1.55
    /// A short reading beat keeps the two sentences distinct without making the
    /// second feel like a separate stage.
    static let interLineDelay: TimeInterval = 0.32
}

final class OnboardingIntroCardContentViewController: CardContentViewController {
    var onContinue: (() -> Void)?
    /// Fired when the first line's reveal completes — the host preloads the
    /// demonstration in the reading pause, never inside a reveal's own turn.
    var onFirstLineRevealed: (() -> Void)?

    private let firstLine: MoonRevealLineView
    private let secondLine: MoonRevealLineView
    private let button = UIButton(type: .system)
    private var didStart = false

    init(
        firstLine: String,
        secondLine: String,
        supportingText _: String
    ) {
        self.firstLine = MoonRevealLineView(text: firstLine)
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
            title: "Let's go",
            symbol: "arrow.right",
            prominent: true)
        // Carry this app's identity into the glass, but keep it a quiet wash
        // rather than the stronger shared prominent-action fill.
        button.configuration?.baseBackgroundColor =
            LunaSurfacePalette.baseColor.withAlphaComponent(0.24)
        button.configuration?.imagePlacement = .trailing
        button.accessibilityLabel = "Let's go"
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
        view.layoutIfNeeded()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(
                OnboardingIntroTiming.firstLineDelay)
        ) { [weak self] in
            guard let self else { return }
            self.revealFirstLine()
        }
    }

    private func revealFirstLine() {
        firstLine.reveal(
            duration: OnboardingIntroTiming.lineRevealDuration
        ) { [weak self] in
            guard let self else { return }
            self.onFirstLineRevealed?()
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
    private let lineSpacing: CGFloat
    private let occluderColor: UIColor
    private var didStartReveal = false
    private var initialCircleFrame = CGRect.zero
    private var edgeSagitta: CGFloat = 0
    private(set) var isFullyRevealed: Bool

    /// The distance the front travels while crossing this view: from the
    /// wide arc's edge first touching the top to its highest point clearing
    /// the bottom. A shared sweep divides this by its front speed so every
    /// element's edge moves at exactly the front's own pace.
    var revealFrontCrossingDistance: CGFloat {
        bounds.height + 2 + edgeSagitta
    }

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

    init(
        text: String,
        initiallyRevealed: Bool = false,
        font: UIFont = .systemFont(ofSize: 25, weight: .semibold),
        textAlignment: NSTextAlignment = .center,
        numberOfLines: Int = 1,
        minimumScaleFactor: CGFloat = 0.72,
        lineSpacing: CGFloat = 0,
        occluderColor: UIColor = .black
    ) {
        self.lineSpacing = lineSpacing
        self.occluderColor = occluderColor
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
            label.font = font
            label.textColor = .white
            label.textAlignment = textAlignment
            label.numberOfLines = numberOfLines
            label.lineBreakMode = .byWordWrapping
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = minimumScaleFactor
            label.isAccessibilityElement = false
            apply(text: text, to: label)
        }
        clippedContent.addSubview(finalLabel)

        guard !initiallyRevealed else { return }
        installOcclusion()
    }

    private func installOcclusion() {
        moonLayer.fillColor = occluderColor.cgColor
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

    /// Returns an already-visible line to its occluded state so `reveal` can
    /// play again — the cleanup pass re-reveals content that loaded plainly.
    func prepareToRevealAgain() {
        guard isFullyRevealed || didStartReveal else { return }
        isFullyRevealed = false
        didStartReveal = false
        isAccessibilityElement = false
        installOcclusion()
        setNeedsLayout()
        layoutIfNeeded()
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
        let travel = revealFrontCrossingDistance
        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration

        // The bloom's display link is the reveal's only clock: occluder,
        // mask and light are all placed from the same per-tick progress, so
        // they cannot drift apart. CAAnimations are deliberately absent —
        // their begin time is stamped when the transaction is encoded, and
        // a backed-up render server starts them already partway through, so
        // the mask snapped fully open in one frame under load. The bloom's
        // cooling distance rides the front's speed: however fast the edge
        // travels, every glyph spends the same TIME brightened and fading
        // back as the intro line's glyphs do — the article-body sweep is
        // ~9× faster than the intro's, so its bands stretch ~9× further.
        let frontSpeed = travel / CGFloat(max(resolvedDuration, 0.001))
        pixelBloomView.reveal(
            circleTravel: travel,
            duration: OnboardingAnimationClock.displayLinkDuration(
                resolvedDuration),
            edgeBandScale: max(
                1, frontSpeed / GlyphPixelBloomView.referenceFrontSpeed),
            onProgress: { [weak self] progress in
                guard let self else { return }
                let offset = travel * progress
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.moonLayer.transform = CATransform3DMakeTranslation(
                    0, offset, 0)
                self.revealMaskLayer.path = self.revealPath(
                    excluding: self.initialCircleFrame.offsetBy(
                        dx: 0, dy: offset))
                CATransaction.commit()
            },
            onCompletion: { [weak self] in
                guard let self, self.didStartReveal else { return }
                self.isFullyRevealed = true
                self.isAccessibilityElement = true
                self.finalLabel.layer.mask = nil
                self.moonLayer.removeFromSuperlayer()
                self.pixelBloomView.removeFromSuperview()
                completion()
            })
    }

    func setText(_ text: String) {
        apply(text: text, to: finalLabel)
        apply(text: text, to: illuminationMaskLabel)
        accessibilityLabel = text
        if !didStartReveal {
            setNeedsLayout()
        }
    }

    private func apply(text: String, to label: UILabel) {
        guard lineSpacing > 0 else {
            label.attributedText = nil
            label.text = text
            return
        }
        let style = NSMutableParagraphStyle()
        style.lineSpacing = lineSpacing
        style.alignment = label.textAlignment
        style.lineBreakMode = label.lineBreakMode
        label.attributedText = NSAttributedString(
            string: text,
            attributes: [
                .font: label.font as Any,
                .foregroundColor: label.textColor as Any,
                .paragraphStyle: style,
            ])
    }

    private func prepareRevealLayers() {
        // A very large circle makes the segment crossing the text nearly
        // horizontal while preserving a real circular distance field.
        let diameter = max(bounds.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = bounds.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        edgeSagitta = sagitta
        // At the line's extreme left/right the edge begins one point above
        // the view's top, so no antialiased pixel leaks out early and the
        // reveal starts exactly as a shared front reaches the view.
        let initialTop = -1 - sagitta
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
/// The FULLY LIT image — the glyph raster with every stacked additive halo
/// pass applied — is rendered ONCE, when the view is configured (for the
/// article that is the primed phase, under the Manage Extensions sheet).
/// During the sweep, a translating gradient mask carves the moving cooling
/// band out of that image: full heat at the descending edge, falling off
/// behind it on the same curve the coarse bands used to approximate, plus a
/// short spill past the edge so glyph halos still lick the unrevealed side.
/// Per display-link tick the only work is moving that mask — the earlier
/// per-frame CPU pipeline (band-clipped raster draws plus eight Quartz
/// shadow blurs, per element) starved the display link to a handful of
/// ticks per sweep and the light advanced in visible plateaus.
///
/// This display link is also the wipe's ONE clock: `onProgress` fires every
/// tick so the owner can place its occluder and reveal mask at exactly the
/// band's own position — light and edge cannot drift apart because they are
/// the same number. CAAnimations are unusable here: their begin time is
/// stamped when the transaction is encoded, so a backed-up render server
/// starts them already partway through (the mask then snaps open with no
/// sweep at all).
///
/// Internal (not private): the mock Safari article's images ride the same
/// light pass, fed a raster of the image instead of glyph alpha.
final class GlyphPixelBloomView: UIView {
    struct HaloPass {
        let radius: CGFloat
        let alpha: CGFloat
    }

    static let renderPadding: CGFloat = 42

    /// The intro line's edge speed (its travel over its reveal duration).
    /// Faster sweeps scale the falloff distances up by speed/reference so a
    /// glyph's brighten-and-cool takes the same TIME at any front speed.
    static let referenceFrontSpeed: CGFloat = 46

    /// The cooling reach behind the edge at the reference speed, and the
    /// falloff exponent — alpha ≈ (1-t)^1.3 matches the midpoints of the
    /// original four coarse bands. The curve is baked into the gradient
    /// mask's stops, so the staircase the coarse bands produced at high
    /// front speeds (line-height slabs of distinct brightness, blinking on
    /// and off) cannot come back: the GPU interpolates the stops smoothly.
    private static let falloffReach: CGFloat = 10.5
    private static let falloffExponent: CGFloat = 1.3
    /// How far the light spills PAST the edge onto not-yet-revealed pixels,
    /// echoing how halos always bled a little beyond the mask.
    private static let edgeSpill: CGFloat = 12

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

    private let litLayer = CALayer()
    private let gradientMask = CAGradientLayer()
    private var glyphImage: UIImage?
    private var glyphFrame = CGRect.zero
    private var initialCircleFrame = CGRect.zero
    private var circleTravel: CGFloat = 0
    private var progress: CGFloat = 0
    private var lastTickTime: CFTimeInterval = 0
    private var revealDuration: CFTimeInterval = 0
    private var displayLink: CADisplayLink?
    private var edgeSagitta: CGFloat = 0
    private var edgeBandScale: CGFloat = 1
    private var rasterScale: CGFloat = 1
    private var emitterGain: CGFloat = 1
    private var onProgress: ((CGFloat) -> Void)?
    private var onCompletion: (() -> Void)?

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
        litLayer.contentsGravity = .resize
        litLayer.isHidden = true
        // ADDITIVE compositing, exactly like the original pipeline's
        // plusLighter draws: light lands on the dark gaps and saturates over
        // the white glyphs, so the text stays crisp under the glow. Composed
        // normally, the baked halo cloud reads as semi-transparent white fog
        // smeared over the glyph edges while it cools — a blurry mess.
        litLayer.compositingFilter = "plusL"
        layer.addSublayer(litLayer)
        gradientMask.startPoint = CGPoint(x: 0.5, y: 0)
        gradientMask.endPoint = CGPoint(x: 0.5, y: 1)
        litLayer.mask = gradientMask
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
        configure(
            raster: glyphRenderer.image { _ in
                glyphLabel.drawText(in: glyphLabel.bounds)
            },
            rasterFrame: glyphFrame,
            circleFrame: circleFrame,
            scale: scale)
    }

    /// The general emitter form: any raster works as the light source — the
    /// halo passes brighten wherever it has alpha, so an image raster whose
    /// alpha was rebuilt from luminance flares exactly the way glyph alpha
    /// does. `emitterGain` scales every pass: thin glyph strokes want the
    /// full 1 (their saturation to a white core is the intro's look), while
    /// a dense photograph saturates even its mid-tones under eight additive
    /// passes and would read as a white slab — its owner lowers the gain so
    /// only genuinely bright pixels reach white heat. Rendering the lit
    /// image happens HERE, once — never during the sweep.
    func configure(
        raster: UIImage,
        rasterFrame: CGRect,
        circleFrame: CGRect,
        scale: CGFloat,
        emitterGain: CGFloat = 1
    ) {
        glyphImage = raster
        glyphFrame = rasterFrame
        initialCircleFrame = circleFrame
        rasterScale = scale
        self.emitterGain = min(max(emitterGain, 0.05), 1)
        progress = 0

        let radius = circleFrame.width / 2
        let halfWidth = bounds.width / 2
        edgeSagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))

        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = false
        // Standard range is LOAD-BEARING: UIGraphicsImageRenderer's default
        // (automatic/extended range) context silently drops CGContext
        // shadows — verified empirically on the iOS 27 simulator with a
        // variant matrix — and the shadows ARE the halos. The old per-frame
        // pipeline never hit this because its shadow passes ran in the
        // view's own draw(_:) backing context.
        format.preferredRange = .standard
        let lit = UIGraphicsImageRenderer(
            bounds: bounds, format: format
        ).image { rendererContext in
            let context = rendererContext.cgContext
            context.setBlendMode(.plusLighter)
            for halo in Self.haloPasses {
                context.saveGState()
                context.setShadow(
                    offset: .zero,
                    blur: halo.radius,
                    color: UIColor.white
                        .withAlphaComponent(halo.alpha * self.emitterGain)
                        .cgColor)
                raster.draw(
                    in: rasterFrame,
                    blendMode: .plusLighter,
                    alpha: self.emitterGain)
                context.restoreGState()
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        litLayer.frame = bounds
        litLayer.contents = lit.cgImage
        litLayer.isHidden = true
        CATransaction.commit()
    }

    /// The widest cooling distance for the current front speed.
    private var scaledFalloffReach: CGFloat {
        Self.falloffReach * edgeBandScale
    }

    func reveal(
        circleTravel: CGFloat,
        duration: CFTimeInterval,
        edgeBandScale: CGFloat = 1,
        onProgress: ((CGFloat) -> Void)? = nil,
        onCompletion: (() -> Void)? = nil
    ) {
        stop()
        self.circleTravel = circleTravel
        self.edgeBandScale = max(edgeBandScale, 1)
        self.onProgress = onProgress
        self.onCompletion = onCompletion
        revealDuration = max(duration, 0.001)
        lastTickTime = 0
        progress = 0

        installGradientMask()
        placeGradientMask()
        litLayer.isHidden = false

        let displayLink = CADisplayLink(
            target: self,
            selector: #selector(advanceRevealFrame(_:)))
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
        onProgress = nil
        onCompletion = nil
    }

    /// Stops encode the (1-t)^exponent cooling curve from cold (top, oldest)
    /// to full heat at the edge, then the short spill past it.
    private func installGradientMask() {
        let reach = scaledFalloffReach
        let height = reach + Self.edgeSpill
        var colors: [CGColor] = []
        var locations: [NSNumber] = []
        let samples = 12
        for sample in 0...samples {
            let fraction = CGFloat(sample) / CGFloat(samples)
            colors.append(
                UIColor.white.withAlphaComponent(
                    pow(fraction, Self.falloffExponent)).cgColor)
            locations.append(NSNumber(value: fraction * reach / height))
        }
        colors.append(UIColor.white.withAlphaComponent(0).cgColor)
        locations.append(NSNumber(value: 1))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientMask.colors = colors
        gradientMask.locations = locations
        gradientMask.bounds = CGRect(
            x: 0, y: 0, width: bounds.width, height: height)
        gradientMask.anchorPoint = .zero
        CATransaction.commit()
    }

    /// The full-heat line rides the arc's mid-height; the flat gradient is
    /// within half a sagitta of the true curved edge everywhere.
    private func placeGradientMask() {
        let edgeY = initialCircleFrame.minY + edgeSagitta / 2
            + circleTravel * progress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        gradientMask.position = CGPoint(x: 0, y: edgeY - scaledFalloffReach)
        CATransaction.commit()
    }

    @objc private func advanceRevealFrame(_ link: CADisplayLink) {
        // Incremental, clamped time: the front advances by real frame time
        // but never more than two frames' worth per tick, so a rendering
        // stall dilates the sweep instead of teleporting the light.
        let dt = lastTickTime == 0
            ? link.targetTimestamp - link.timestamp
            : min(link.timestamp - lastTickTime, 2.0 / 60.0)
        progress = min(progress + CGFloat(dt / revealDuration), 1)
        placeGradientMask()
        onProgress?(progress)
        if progress >= 1 {
            let completion = onCompletion
            stop()
            litLayer.isHidden = true
            completion?()
        }
    }
}
