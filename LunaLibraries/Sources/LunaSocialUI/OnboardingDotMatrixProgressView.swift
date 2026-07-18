//
//  OnboardingDotMatrixProgressView.swift
//  LunaSocialUI
//
//  A step-progress indicator for the onboarding flow, drawn as rounded-square
//  dots: one per step — completed and current steps filled in the
//  reading accent, upcoming steps dimmed. The current step's dot pulses gently
//  (Core Animation, presentation-layer only) unless Reduce Motion is on.
//

import LunaDesignSystem
import QuartzCore
import UIKit

/// "Step X of Y" as a row of dot-matrix dots.
public final class OnboardingDotMatrixProgressView: UIView {

    private let currentIndex: Int
    private let totalSteps: Int

    private let dotSide: CGFloat = 8
    private let dotSpacing: CGFloat = 10
    private var dotCornerRadius: CGFloat { dotSide / 3 }

    private var dotLayers: [CALayer] = []
    private var motionObserver: NSObjectProtocol?

    public init(currentIndex: Int, totalSteps: Int) {
        self.currentIndex = max(0, min(currentIndex, totalSteps - 1))
        self.totalSteps = max(1, totalSteps)
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        buildDots()

        isAccessibilityElement = true
        accessibilityTraits = .staticText
        accessibilityLabel = "Step \(self.currentIndex + 1) of \(self.totalSteps)"

        motionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshPulse() }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }

    // MARK: Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(width: CGFloat(totalSteps) * dotSide + CGFloat(totalSteps - 1) * dotSpacing,
               height: dotSide)
    }

    private func buildDots() {
        dotLayers = (0..<totalSteps).map { _ in
            let dot = CALayer()
            dot.cornerRadius = dotCornerRadius
            layer.addSublayer(dot)
            return dot
        }
        applyColors()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let originX = (bounds.width - intrinsicContentSize.width) / 2
        let originY = (bounds.height - dotSide) / 2
        for (index, dot) in dotLayers.enumerated() {
            dot.frame = CGRect(
                x: originX + CGFloat(index) * (dotSide + dotSpacing),
                y: originY, width: dotSide, height: dotSide)
        }
        CATransaction.commit()
    }

    private func applyColors() {
        let accent = GlassStyle.lunaBrandAccent.resolvedColor(with: traitCollection).cgColor
        let dim = UIColor.label.resolvedColor(with: traitCollection).withAlphaComponent(0.18).cgColor
        for (index, dot) in dotLayers.enumerated() {
            dot.backgroundColor = index <= currentIndex ? accent : dim
        }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyColors()
        }
    }

    // MARK: Pulse

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshPulse()
    }

    /// The current step's dot breathes gently. Presentation-layer only (the model
    /// layer stays fully opaque/unscaled, so `layer.render(in:)` snapshots are
    /// deterministic); frozen entirely under Reduce Motion.
    private func refreshPulse() {
        let dot = dotLayers[currentIndex]
        dot.removeAnimation(forKey: pulseKey)
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }

        let scale = CAKeyframeAnimation(keyPath: "transform.scale")
        scale.values = [1.0, 1.3, 1.0]
        scale.keyTimes = [0, 0.5, 1]

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [1.0, 0.6, 1.0]
        opacity.keyTimes = [0, 0.5, 1]

        let group = CAAnimationGroup()
        group.animations = [scale, opacity]
        group.duration = 1.4
        group.repeatCount = .infinity
        group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        group.isRemovedOnCompletion = false
        dot.add(group, forKey: pulseKey)
    }

    private let pulseKey = "onboardingProgressPulse"
}
