//
//  EclipseProgressBar.swift
//  LunaDesignSystem
//

import LunaModels
import UIKit

/// A determinate progress bar drawn as a **total eclipse in transit**: a dim
/// track ahead, a gathering rim of coronal light behind, and at the head of
/// progress the eclipse itself — a dark lunar disc ringed by a bright corona
/// that blooms outward.
///
/// Sibling to `MoonHorizonProgressBar` and deliberately distinct from it: the
/// horizon bar is Luna's *ambient* progress (a download filling, playback
/// advancing), while this one marks a **single foreground operation the user is
/// waiting on**, so it wants a heavier, more arresting head. Same trait rules
/// as every other cached-`CGColor` view — a `LunaSkyTrait` change is the only
/// notification a repaint will ever get (`claudedocs/visual-effects.md`).
public final class EclipseProgressBar: UIView {

    /// Geometry. The disc is the widest thing here, so the bar's height is set
    /// by the disc plus room for its corona to bloom.
    private static let trackHeight: CGFloat = 3
    private static let discDiameter: CGFloat = 16
    private static let coronaLineWidth: CGFloat = 1.6
    private static let coronaGlowRadius: CGFloat = 7

    private let trackLayer = CAShapeLayer()
    /// The lit stretch behind the head: a left-to-right ramp (nearly nothing at
    /// the far left, full strength just behind the disc) masked to the track.
    private let litGradient = CAGradientLayer()
    private let litMask = CAShapeLayer()
    /// The occulting body — a hole in the light, not a dot of it.
    private let discLayer = CAShapeLayer()
    /// The corona: a ring stroked around the disc whose shadow blooms outward.
    private let coronaLayer = CAShapeLayer()
    /// The slow breath that keeps the corona alive while a fraction sits still.
    private var isBreathing = false

    public private(set) var progress: Float = 0

    /// Whether the corona pulses gently while the bar is on screen. On by
    /// default: this bar exists to show that something long-running is still
    /// alive, and a stalled model call would otherwise look frozen.
    public var showsCoronaBreath = true {
        didSet {
            guard showsCoronaBreath != oldValue else { return }
            updateBreath()
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = L10n.string("Progress")

        trackLayer.strokeColor = nil
        layer.addSublayer(trackLayer)

        litMask.fillColor = UIColor.white.cgColor
        litGradient.startPoint = CGPoint(x: 0, y: 0.5)
        litGradient.endPoint = CGPoint(x: 1, y: 0.5)
        litGradient.mask = litMask
        layer.addSublayer(litGradient)

        discLayer.strokeColor = nil
        layer.addSublayer(discLayer)

        coronaLayer.fillColor = nil
        coronaLayer.lineWidth = Self.coronaLineWidth
        coronaLayer.shadowRadius = Self.coronaGlowRadius
        coronaLayer.shadowOpacity = 1
        coronaLayer.shadowOffset = .zero
        layer.addSublayer(coronaLayer)

        updateAppearanceColors()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: Self, _: UITraitCollection) in
            self.updateAppearanceColors()
        }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.discDiameter + 8)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBreath()
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Traits can settle after init (an ancestor applying the appearance
        // before this view reaches a window), so re-resolve on every layout.
        updateAppearanceColors()
        trackLayer.path = trackPath()
        litMask.path = trackPath()
        litMask.frame = bounds
        litGradient.frame = bounds
        applyHead(fraction: CGFloat(progress))
        CATransaction.commit()
    }

    /// Sets the fraction (clamped to 0…1). `animated` interpolates the head's
    /// travel — the caller animates only when the new value came from real
    /// forward motion, never when re-applying the same state.
    public func setProgress(_ value: Float, animated: Bool) {
        let clamped = min(max(value, 0), 1)
        progress = clamped
        accessibilityValue = "\(Int(clamped * 100))%"
        guard bounds.width > 0 else { return }
        if animated {
            applyHead(fraction: CGFloat(clamped))
        } else {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            applyHead(fraction: CGFloat(clamped))
            CATransaction.commit()
        }
    }

    // MARK: - Geometry

    /// The track's capsule, inset by the disc's radius at both ends so the disc
    /// stays fully inside the bar at 0 and at 1.
    private var trackRect: CGRect {
        let radius = Self.discDiameter / 2
        return CGRect(
            x: radius, y: (bounds.height - Self.trackHeight) / 2,
            width: max(0, bounds.width - Self.discDiameter), height: Self.trackHeight)
    }

    private func trackPath() -> CGPath {
        UIBezierPath(roundedRect: trackRect, cornerRadius: Self.trackHeight / 2).cgPath
    }

    private func applyHead(fraction: CGFloat) {
        let rect = trackRect
        let centerX = rect.minX + rect.width * fraction
        let radius = Self.discDiameter / 2
        let discRect = CGRect(
            x: centerX - radius, y: bounds.midY - radius,
            width: Self.discDiameter, height: Self.discDiameter)
        let disc = UIBezierPath(ovalIn: discRect).cgPath
        discLayer.path = disc
        // The corona is stroked ON the disc's edge, so half its width sits
        // outside the occulting body and half inside — a rim, not an outline.
        coronaLayer.path = disc
        coronaLayer.shadowPath = disc
        // Light exists only behind the head: at 0 there is no lit stretch at all.
        litGradient.isHidden = fraction <= 0.001
        litMask.frame = CGRect(x: 0, y: 0, width: centerX, height: bounds.height)
    }

    // MARK: - Colors

    private func updateAppearanceColors() {
        let corona = MoonHorizonStyle.sunlight.resolvedColor(with: traitCollection)
        let core = MoonHorizonStyle.sunCore.resolvedColor(with: traitCollection)
        trackLayer.fillColor = MoonHorizonStyle.darkHorizon(for: traitCollection).cgColor
        litGradient.colors = [
            corona.withAlphaComponent(0.05).cgColor,
            corona.withAlphaComponent(0.35).cgColor,
            core.withAlphaComponent(0.85).cgColor,
        ]
        litGradient.locations = [0, 0.55, 1]
        // The moon reads as an absence of light, so it takes the darkest tone
        // available rather than a grey that would look like a bead on a string.
        discLayer.fillColor = UIColor.black.withAlphaComponent(
            traitCollection.lunaSky == .night ? 1.0 : 0.92).cgColor
        coronaLayer.strokeColor = core.withAlphaComponent(0.9).cgColor
        coronaLayer.shadowColor = corona.withAlphaComponent(0.85).cgColor
    }

    // MARK: - Breath

    private func updateBreath() {
        let shouldBreathe = window != nil && showsCoronaBreath
            && !UIAccessibility.isReduceMotionEnabled
        guard shouldBreathe != isBreathing else { return }
        isBreathing = shouldBreathe
        guard shouldBreathe else {
            coronaLayer.removeAnimation(forKey: "breath")
            coronaLayer.shadowOpacity = 1
            return
        }
        let breath = CABasicAnimation(keyPath: "shadowOpacity")
        breath.fromValue = 0.45
        breath.toValue = 1.0
        breath.duration = 1.4
        breath.autoreverses = true
        breath.repeatCount = .infinity
        breath.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        coronaLayer.add(breath, forKey: "breath")
    }
}
