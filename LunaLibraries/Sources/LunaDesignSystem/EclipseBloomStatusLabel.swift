//
//  EclipseBloomStatusLabel.swift
//  LunaDesignSystem
//

import UIKit
import LunaModels

/// A status label revealed by the onboarding eclipse front: a large black moon
/// descends through the text while a white-hot bloom peaks at the edge, then the
/// glyphs settle to their configured colour. It is intentionally reusable by
/// loading screens in every Luna surface and extension.
public final class EclipseBloomStatusLabel: UIView {
    private let finalLabel = UILabel()
    /// A pure-white twin used only as the glyph-alpha source for the same
    /// raster bloom renderer as the onboarding utility-card headline.
    private let illuminationMaskLabel = UILabel()
    private let revealMask = CAShapeLayer()
    /// Frozen outgoing ink, visible only ahead of the same edge that reveals
    /// the incoming label. It never draws over the incoming glyphs.
    private let outgoingInk = CALayer()
    private let outgoingMask = CAShapeLayer()
    /// A transparent copy of the onboarding moon front. Its presentation
    /// transform is the bloom renderer's clock, keeping the light attached to
    /// the actual mask edge instead of letting two independent animations drift.
    private let frontTracker = CAShapeLayer()
    private let pixelBloomView = GlyphPixelBloomView()
    private var isRevealing = false
    private var revealGeneration = 0
    private var requestedText: String?
    /// Set when `reveal` was asked for before this view had a size: the words are
    /// already applied, and this is the sweep still owed once layout provides bounds.
    private var pendingRevealDuration: TimeInterval?

    public var text: String? { finalLabel.text }
    public var textColor: UIColor = LunaColors.secondaryText {
        didSet { finalLabel.textColor = textColor }
    }
    public var font: UIFont = .preferredFont(forTextStyle: .body) {
        didSet { [finalLabel, illuminationMaskLabel].forEach { $0.font = font } }
    }
    public var textAlignment: NSTextAlignment = .center {
        didSet {
            [finalLabel, illuminationMaskLabel].forEach { $0.textAlignment = textAlignment }
        }
    }
    public var numberOfLines: Int = 1 {
        didSet {
            [finalLabel, illuminationMaskLabel].forEach { $0.numberOfLines = numberOfLines }
        }
    }

    /// Test/diagnostic evidence that this status label is configured with the
    /// onboarding renderer rather than a whole-label shadow approximation.
    public var usesOnboardingGlyphBloom: Bool {
        pixelBloomView.usesRasterizedGlyphPixels
            && pixelBloomView.usesStackedAdditiveHalos
    }

    #if DEBUG
    /// The duration the most recent `reveal` actually animated with, after the
    /// Reduce Motion override — evidence that a caller's requested speed (the
    /// cycler's near-instant first bloom, its unchanged rotation sweep) reached
    /// the animation rather than being silently ignored.
    public private(set) var lastResolvedRevealDurationForTesting: TimeInterval?
    public var outgoingInkForTesting: CALayer { outgoingInk }
    #endif

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clipsToBounds = false
        for label in [finalLabel, illuminationMaskLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textAlignment = textAlignment
            label.numberOfLines = numberOfLines
            label.font = font
        }
        addSubview(finalLabel)
        NSLayoutConstraint.activate([
            finalLabel.topAnchor.constraint(equalTo: topAnchor),
            finalLabel.bottomAnchor.constraint(equalTo: bottomAnchor),
            finalLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            finalLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        finalLabel.textColor = textColor
        illuminationMaskLabel.textColor = .white
        frontTracker.fillColor = UIColor.clear.cgColor
        layer.addSublayer(frontTracker)
        outgoingInk.contentsGravity = .resize
        outgoingInk.isHidden = true
        layer.addSublayer(outgoingInk)
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    /// Sets the text plainly, for terminal errors and other non-loading states.
    ///
    /// Also CANCELS any parked reveal. A terminal message arrives exactly when the
    /// loading copy is being abandoned (rate-limited, un-archivable), and a reveal
    /// still owed from before layout would otherwise fire on the next pass and put
    /// "Unlocking article…" back over the error.
    public func setTextImmediately(_ text: String?) {
        revealGeneration &+= 1
        stopReveal()
        finalLabel.text = text
        illuminationMaskLabel.text = text
        finalLabel.alpha = 1
        requestedText = text
        pendingRevealDuration = nil
    }

    /// Uses the same top-down eclipse pacing as the onboarding intro's first line.
    ///
    /// The TEXT is applied before the size check, and that ordering is load-bearing.
    /// This view has no intrinsic size of its own — it takes the size of the labels
    /// pinned inside it. If the bounds guard below ran before the text were set, the
    /// labels would stay empty, their width would stay zero, and the bounds could
    /// never become non-zero: `layoutSubviews`' retry would re-enter the same guard
    /// forever, and the caller's status copy would never appear. This matters most
    /// for a surface that starts its cycler in view setup, before its first layout
    /// pass — the action extension, the archive reader.
    ///
    /// So: set the text first (that alone gives the view a size), then either animate
    /// now or park the reveal for `layoutSubviews` to run once there are bounds to
    /// animate within.
    public func reveal(_ text: String, duration: TimeInterval = 1.55) {
        revealGeneration &+= 1
        stopReveal()
        // Capture the previous phrase at its settled screen position before
        // changing intrinsic size. The snapshot has no bloom or reveal mask.
        let outgoingFrame = finalLabel.convert(finalLabel.bounds, to: superview)
        let outgoingImage: UIImage? = finalLabel.text.flatMap { previous in
            guard pendingRevealDuration == nil, !previous.isEmpty,
                  !finalLabel.bounds.isEmpty else { return nil }
            let format = UIGraphicsImageRendererFormat()
            format.scale = traitCollection.displayScale
            return UIGraphicsImageRenderer(size: finalLabel.bounds.size, format: format)
                .image { finalLabel.layer.render(in: $0.cgContext) }
        }
        requestedText = text
        finalLabel.text = text
        illuminationMaskLabel.text = text
        finalLabel.alpha = 1
        guard bounds.width > 0, bounds.height > 0 else {
            // No bounds yet: the words are already on screen-bound labels, and the
            // eclipse sweep runs as soon as layout gives them a rect.
            pendingRevealDuration = duration
            finalLabel.layer.mask = nil
            isRevealing = false
            setNeedsLayout()
            return
        }
        pendingRevealDuration = nil
        isRevealing = true

        // Applying new text invalidates the label's intrinsic size. Resolve the
        // entire containing layout BEFORE capturing glyphs or installing masks;
        // otherwise the next layout moves the ink away from its bloom raster.
        var layoutRoot: UIView = self
        while let parent = layoutRoot.superview { layoutRoot = parent }
        layoutRoot.setNeedsLayout()
        layoutRoot.layoutIfNeeded()
        layoutIfNeeded()
        let rect = finalLabel.bounds
        let previousRect = convert(outgoingFrame, from: superview)
        let sweepRect = outgoingImage == nil ? rect : rect.union(previousRect)
        let diameter = max(sweepRect.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = sweepRect.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        let initial = CGRect(
            x: sweepRect.midX - radius, y: sweepRect.minY - 1 - sagitta,
            width: diameter, height: diameter)
        let travel = sweepRect.height + 2 + sagitta
        let final = initial.offsetBy(dx: 0, dy: travel)
        let initialPath = revealPath(excluding: initial, in: rect)
        let finalPath = revealPath(excluding: final, in: rect)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.fillRule = .evenOdd
        revealMask.fillColor = UIColor.white.cgColor
        revealMask.frame = rect
        revealMask.path = finalPath
        finalLabel.layer.mask = revealMask
        outgoingInk.frame = previousRect
        outgoingInk.contentsScale = traitCollection.displayScale
        outgoingInk.contents = outgoingImage?.cgImage
        outgoingInk.isHidden = outgoingImage == nil
        outgoingMask.frame = outgoingInk.bounds
        outgoingMask.fillColor = UIColor.white.cgColor
        let outgoingInitialPath = UIBezierPath(ovalIn: initial.offsetBy(
            dx: -previousRect.minX, dy: -previousRect.minY)).cgPath
        let outgoingFinalPath = UIBezierPath(ovalIn: final.offsetBy(
            dx: -previousRect.minX, dy: -previousRect.minY)).cgPath
        outgoingMask.path = outgoingFinalPath
        outgoingInk.mask = outgoingMask
        frontTracker.frame = rect
        frontTracker.path = UIBezierPath(ovalIn: initial).cgPath
        let frontTransform = CATransform3DMakeTranslation(0, travel, 0)
        frontTracker.transform = frontTransform
        CATransaction.commit()

        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        #if DEBUG
        lastResolvedRevealDurationForTesting = resolvedDuration
        #endif
        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = initialPath
        maskAnimation.toValue = finalPath
        maskAnimation.duration = resolvedDuration
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealMask.add(maskAnimation, forKey: "eclipseGlyphReveal")
        let outgoingAnimation = CABasicAnimation(keyPath: "path")
        outgoingAnimation.duration = resolvedDuration
        outgoingAnimation.timingFunction = maskAnimation.timingFunction
        outgoingAnimation.fromValue = outgoingInitialPath
        outgoingAnimation.toValue = outgoingFinalPath
        outgoingMask.add(outgoingAnimation, forKey: "eclipseGlyphConceal")

        let trackerAnimation = CABasicAnimation(keyPath: "transform")
        trackerAnimation.fromValue = CATransform3DIdentity
        trackerAnimation.toValue = frontTransform
        trackerAnimation.duration = resolvedDuration
        trackerAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        frontTracker.add(trackerAnimation, forKey: "eclipseBloomFront")

        // This is the onboarding utility-card headline's actual rasterized
        // glyph-edge light—not a second full label with a shadow. Only pixels
        // beside the moving moon front emit, then cool behind it.
        illuminationMaskLabel.frame = rect
        illuminationMaskLabel.layoutIfNeeded()
        let padding = GlyphPixelBloomView.renderPadding
        pixelBloomView.frame = rect.insetBy(dx: -padding, dy: -padding)
        if pixelBloomView.superview == nil { addSubview(pixelBloomView) }
        pixelBloomView.configure(
            glyphLabel: illuminationMaskLabel,
            glyphFrame: CGRect(
                x: padding, y: padding,
                width: rect.width, height: rect.height),
            circleFrame: initial.offsetBy(dx: padding, dy: padding),
            scale: traitCollection.displayScale)
        let frontSpeed = travel / CGFloat(max(resolvedDuration, 0.001))
        pixelBloomView.reveal(
            circleTravel: travel,
            duration: resolvedDuration,
            edgeBandScale: max(
                1, frontSpeed / GlyphPixelBloomView.referenceFrontSpeed),
            offsetProvider: { [weak frontTracker] in
                frontTracker?.presentation().map { CGFloat($0.transform.m42) }
            })

        let generation = revealGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + resolvedDuration) { [weak self] in
            guard let self, self.revealGeneration == generation else { return }
            self.stopReveal()
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Run a reveal that was asked for before there were bounds to sweep. Keyed on
        // the parked duration rather than on `finalLabel.text != requestedText`: since
        // `reveal` sets the text up front, that comparison can never be true.
        guard let duration = pendingRevealDuration, let requestedText,
              !isRevealing, bounds.width > 0, bounds.height > 0
        else { return }
        reveal(requestedText, duration: duration)
    }

    private func stopReveal() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        revealMask.removeAllAnimations()
        outgoingMask.removeAllAnimations()
        outgoingInk.contents = nil
        outgoingInk.isHidden = true
        frontTracker.removeAllAnimations()
        frontTracker.transform = CATransform3DIdentity
        pixelBloomView.stop()
        pixelBloomView.removeFromSuperview()
        finalLabel.layer.mask = nil
        isRevealing = false
        CATransaction.commit()
    }

    private func revealPath(excluding circle: CGRect, in rect: CGRect) -> CGPath {
        let path = UIBezierPath(rect: rect)
        path.append(UIBezierPath(ovalIn: circle))
        path.usesEvenOddFillRule = true
        return path.cgPath
    }
}

/// Rotates article-loading reassurance after a short grace period. The initial
/// phrase is always the caller's current wording; every replacement is chosen
/// at random and enters through `EclipseBloomStatusLabel`'s eclipse bloom.
public final class ArticleLoadingStatusCycler {
    private weak var label: EclipseBloomStatusLabel?
    private let initialText: String
    private let alternatives: [String]
    private var timer: Timer?
    private var unusedAlternatives: [String] = []

    /// How long each phrase holds before the next one takes over. A parameter
    /// only so a test can watch a rotation happen without waiting out the
    /// shipped pacing; every call site takes the default.
    private let interval: TimeInterval

    /// How long the FIRST phrase's bloom takes to sweep in. A spinner that has
    /// just appeared has nothing to hold continuity with yet, so this defaults
    /// to barely perceptible rather than `EclipseBloomStatusLabel.reveal`'s own
    /// full sweep — every ROTATION after it still calls `reveal` with no
    /// duration override at all, i.e. the same sweep it has always used.
    private let initialRevealDuration: TimeInterval

    /// Near-instant, but not zero: the bloom stays the same animation, just
    /// too quick to watch happen.
    public static let instantRevealDuration: TimeInterval = 0.05

    public init(
        label: EclipseBloomStatusLabel,
        initialText: String,
        interval: TimeInterval = 3,
        initialRevealDuration: TimeInterval = ArticleLoadingStatusCycler.instantRevealDuration,
        alternatives: [String] = [
            L10n.string("LoadingStatus_stage1_stillGoing"),
            L10n.string("LoadingStatus_stage2_justABitLonger"),
            L10n.string("LoadingStatus_stage3_findingTheGoodPart"),
            L10n.string("LoadingStatus_stage4_nearlyThere"),
        ]
    ) {
        self.label = label
        self.initialText = initialText
        self.interval = interval
        self.initialRevealDuration = initialRevealDuration
        self.alternatives = alternatives
    }

    deinit { stop() }

    public func start() {
        stop()
        label?.reveal(initialText, duration: initialRevealDuration)
        timer = Timer.scheduledTimer(
            withTimeInterval: interval, repeats: true
        ) { [weak self] _ in self?.showNextPhrase() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func showNextPhrase() {
        guard let label, !alternatives.isEmpty else { return }
        if unusedAlternatives.isEmpty {
            unusedAlternatives = alternatives.shuffled()
        }
        label.reveal(unusedAlternatives.removeFirst())
    }
}
