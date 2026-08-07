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
    private let bloomLabel = UILabel()
    private let revealMask = CAShapeLayer()
    private var isRevealing = false
    private var requestedText: String?
    /// Set when `reveal` was asked for before this view had a size: the words are
    /// already applied, and this is the sweep still owed once layout provides bounds.
    private var pendingRevealDuration: TimeInterval?

    public var text: String? { finalLabel.text }
    public var textColor: UIColor = LunaColors.secondaryText {
        didSet { finalLabel.textColor = textColor }
    }
    public var font: UIFont = .preferredFont(forTextStyle: .body) {
        didSet { [finalLabel, bloomLabel].forEach { $0.font = font } }
    }
    public var textAlignment: NSTextAlignment = .center {
        didSet { [finalLabel, bloomLabel].forEach { $0.textAlignment = textAlignment } }
    }
    public var numberOfLines: Int = 1 {
        didSet { [finalLabel, bloomLabel].forEach { $0.numberOfLines = numberOfLines } }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        for label in [finalLabel, bloomLabel] {
            label.translatesAutoresizingMaskIntoConstraints = false
            label.textAlignment = textAlignment
            label.numberOfLines = numberOfLines
            label.font = font
            addSubview(label)
            NSLayoutConstraint.activate([
                label.topAnchor.constraint(equalTo: topAnchor),
                label.bottomAnchor.constraint(equalTo: bottomAnchor),
                label.leadingAnchor.constraint(equalTo: leadingAnchor),
                label.trailingAnchor.constraint(equalTo: trailingAnchor),
            ])
        }
        finalLabel.textColor = textColor
        bloomLabel.textColor = .white
        bloomLabel.alpha = 0
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
        layer.removeAllAnimations()
        finalLabel.layer.removeAllAnimations()
        bloomLabel.layer.removeAllAnimations()
        finalLabel.layer.mask = nil
        finalLabel.text = text
        bloomLabel.text = text
        finalLabel.alpha = 1
        bloomLabel.alpha = 0
        isRevealing = false
        requestedText = text
        pendingRevealDuration = nil
    }

    /// Uses the same top-down eclipse pacing as the onboarding intro's first line.
    ///
    /// The TEXT is applied before the size check, and that ordering is load-bearing.
    /// This view has no intrinsic size of its own — it takes the size of the labels
    /// pinned inside it — so a `reveal` that returned early WITHOUT setting the text
    /// (which is what the bounds guard used to do) left a view whose labels were
    /// empty, whose width was therefore zero, and whose bounds could never become
    /// non-zero: `layoutSubviews`' retry re-entered the same guard forever and the
    /// caller's status copy never appeared at all. Every loading surface that starts
    /// its cycler in view setup — the action extension, the archive reader — was
    /// asking for text before its first layout pass, so none of them ever showed a
    /// word, including the rotating "Still going…" reassurance.
    ///
    /// So: set the text first (that alone gives the view a size), then either animate
    /// now or park the reveal for `layoutSubviews` to run once there are bounds to
    /// animate within.
    public func reveal(_ text: String, duration: TimeInterval = 1.55) {
        requestedText = text
        finalLabel.text = text
        bloomLabel.text = text
        finalLabel.alpha = 1
        bloomLabel.alpha = 0
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

        let rect = finalLabel.bounds
        let diameter = max(rect.width * 8, 1_200)
        let radius = diameter / 2
        let halfWidth = rect.width / 2
        let sagitta = radius - sqrt(max(radius * radius - halfWidth * halfWidth, 0))
        let initial = CGRect(
            x: rect.midX - radius, y: -1 - sagitta,
            width: diameter, height: diameter)
        let travel = rect.height + 2 + sagitta
        let final = initial.offsetBy(dx: 0, dy: travel)
        let initialPath = revealPath(excluding: initial, in: rect)
        let finalPath = revealPath(excluding: final, in: rect)

        revealMask.fillRule = .evenOdd
        revealMask.fillColor = UIColor.white.cgColor
        revealMask.frame = rect
        revealMask.path = finalPath
        finalLabel.layer.mask = revealMask

        let resolvedDuration = UIAccessibility.isReduceMotionEnabled ? 0.24 : duration
        let maskAnimation = CABasicAnimation(keyPath: "path")
        maskAnimation.fromValue = initialPath
        maskAnimation.toValue = finalPath
        maskAnimation.duration = resolvedDuration
        maskAnimation.timingFunction = CAMediaTimingFunction(name: .linear)
        revealMask.add(maskAnimation, forKey: "eclipseGlyphReveal")

        // A stacked white glow produces the same brief white-hot bloom as the
        // onboarding text before the glyphs cool to their normal status colour.
        bloomLabel.layer.shadowColor = UIColor.white.cgColor
        bloomLabel.layer.shadowOffset = .zero
        bloomLabel.layer.shadowRadius = 18
        let bloom = CAKeyframeAnimation(keyPath: "opacity")
        bloom.values = [0, 0.9, 1, 0]
        bloom.keyTimes = [0, 0.18, 0.42, 1]
        bloom.duration = resolvedDuration
        bloomLabel.layer.add(bloom, forKey: "eclipseBloom")
        let shadow = CAKeyframeAnimation(keyPath: "shadowOpacity")
        shadow.values = [0, 0.75, 1, 0]
        shadow.keyTimes = bloom.keyTimes
        shadow.duration = resolvedDuration
        bloomLabel.layer.add(shadow, forKey: "eclipseBloomShadow")

        DispatchQueue.main.asyncAfter(deadline: .now() + resolvedDuration) { [weak self] in
            guard let self, self.requestedText == text else { return }
            self.finalLabel.layer.mask = nil
            self.bloomLabel.alpha = 0
            self.isRevealing = false
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        // Run a reveal that was asked for before there were bounds to sweep. Keyed on
        // the parked duration rather than on `finalLabel.text != requestedText`, which
        // can no longer be the signal now that the text is applied up front.
        guard let duration = pendingRevealDuration, let requestedText,
              !isRevealing, bounds.width > 0, bounds.height > 0
        else { return }
        reveal(requestedText, duration: duration)
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

    public init(
        label: EclipseBloomStatusLabel,
        initialText: String,
        interval: TimeInterval = 3,
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
        self.alternatives = alternatives
    }

    deinit { stop() }

    public func start() {
        stop()
        label?.reveal(initialText)
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
