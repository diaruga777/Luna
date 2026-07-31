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
    public func setTextImmediately(_ text: String?) {
        layer.removeAllAnimations()
        finalLabel.layer.removeAllAnimations()
        bloomLabel.layer.removeAllAnimations()
        finalLabel.layer.mask = nil
        finalLabel.text = text
        finalLabel.alpha = 1
        bloomLabel.alpha = 0
        isRevealing = false
    }

    /// Uses the same top-down eclipse pacing as the onboarding intro's first line.
    public func reveal(_ text: String, duration: TimeInterval = 1.55) {
        requestedText = text
        guard bounds.width > 0, bounds.height > 0 else {
            setNeedsLayout()
            return
        }
        finalLabel.text = text
        bloomLabel.text = text
        finalLabel.alpha = 1
        bloomLabel.alpha = 0
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
        if let requestedText, !isRevealing, finalLabel.text != requestedText {
            reveal(requestedText)
        }
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

    public init(
        label: EclipseBloomStatusLabel,
        initialText: String,
        alternatives: [String] = [
            L10n.string("Still going…"),
            L10n.string("Just a bit longer…"),
            L10n.string("Finding the good part…"),
            L10n.string("Nearly there…"),
        ]
    ) {
        self.label = label
        self.initialText = initialText
        self.alternatives = alternatives
    }

    deinit { stop() }

    public func start() {
        stop()
        label?.reveal(initialText)
        timer = Timer.scheduledTimer(
            withTimeInterval: 3, repeats: true
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
