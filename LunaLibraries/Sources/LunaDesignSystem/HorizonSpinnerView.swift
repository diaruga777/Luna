//
//  HorizonSpinnerView.swift
//  LunaDesignSystem
//
//  Luna's shared indeterminate activity treatment: `HorizonScrollIndicator`'s
//  visual language — a faint tinted track with one brilliant point of light
//  riding it — bent into a closed ring. The head orbits forever at a swelling,
//  easing pace, and on its own slower cycle a second, dimmer point separates
//  from it, takes one lap of its own, and merges back in a brief flare, exactly
//  as the pulse does on `MoonHorizonProgressBar`.
//

import QuartzCore
import UIKit
import LunaModels

/// An indeterminate horizon activity indicator. It deliberately has the same
/// small API as `UIActivityIndicatorView`, so it can be used in every app and
/// extension without host-specific animation work.
public final class HorizonSpinnerView: UIView {

    // MARK: Geometry

    /// The ring's share of the view's half-width. The rest is headroom: the
    /// head's bloom is wider than the ring's own stroke and spills outward.
    private static let ringScale: CGFloat = 0.88
    /// Bloom-to-core ratio, taken straight from `HorizonScrollIndicator`
    /// (26pt bloom around a 3pt core) so the point reads identically here.
    private static let bloomToCore: CGFloat = 26.0 / 3.0
    private static let flareToBloom: CGFloat = 34.0 / 26.0
    /// Same faint tint `HorizonScrollIndicator` gives its unlit track.
    private static let trackAlpha: CGFloat = 0.22

    // MARK: Motion

    /// One lap of the head. Its *angular speed* is not constant: it swells and
    /// eases `headSpeedCycles` times per lap, between `1 ± headSpeedSwing` of
    /// the mean — never stalling, the way a stalling spinner reads as stuck.
    ///
    /// The lap and pulse durations are scaled with `ringScale`, so widening the
    /// ring leaves the light travelling at the same speed *along* it rather than
    /// whipping around a bigger circle in the same time.
    private static let lapDuration: CFTimeInterval = 2.0
    private static let headSpeedSwing: CGFloat = 0.62
    private static let headSpeedCycles: CGFloat = 2
    /// The second point's own cycle: one relative lap, then a rest before it
    /// separates again. Deliberately not a multiple of `lapDuration`, so the
    /// merge lands somewhere new on the ring every time.
    private static let pulseTravelDuration: CFTimeInterval = 2.45
    private static let pulseCycleDuration: CFTimeInterval = 4.0
    /// Negative: the pulse drifts off the head slowly, races the far side, and
    /// eases back in rather than arriving at speed.
    private static let pulseSpeedSwing: CGFloat = -0.55
    /// Seconds before the merge that the flare begins to swell.
    private static let flareLead: CFTimeInterval = 0.12
    private static let flareDuration: CFTimeInterval = 0.45

    // MARK: Layers

    /// The faint, per-app-tinted ring the head rides.
    private let trackLayer = CAShapeLayer()
    /// Carries everything that orbits, so one rotation animation moves the
    /// head, the pulse's frame of reference, and the merge flare together.
    private let orbitLayer = CALayer()
    /// The sun's steep radial bloom around the head point.
    private let headBloomLayer = CAGradientLayer()
    /// The white-hot core point itself.
    private let headCoreLayer = CALayer()
    /// The pulse's own frame of reference: rotating this within `orbitLayer`
    /// walks the second point away from the head and all the way back to it.
    private let pulseOrbitLayer = CALayer()
    private let pulseBloomLayer = CAGradientLayer()
    private let pulseCoreLayer = CALayer()
    /// The brief burst where pulse and head merge, brighter than either alone.
    private let flareLayer = CAGradientLayer()

    private let side: CGFloat

    /// The halo uses the horizon palette. Setting `color` tints that halo while
    /// keeping its white-hot core, just like a lunar horizon head.
    public var color: UIColor = MoonHorizonStyle.sunlight {
        didSet { applyColors() }
    }

    public var hidesWhenStopped: Bool = true {
        didSet {
            if hidesWhenStopped {
                if !isAnimating { isHidden = true }
            } else {
                isHidden = false
            }
        }
    }

    public private(set) var isAnimating = false

    // MARK: Init

    /// - Parameter side: Overall square size in points.
    public init(side: CGFloat = 26) {
        self.side = max(12, side)
        super.init(frame: CGRect(x: 0, y: 0, width: self.side, height: self.side))
        commonInit()
    }

    public required init?(coder: NSCoder) {
        side = 26
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        // The bloom is wider than the ring by design; never clip it.
        clipsToBounds = false
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = L10n.string("Loading")

        trackLayer.fillColor = nil
        trackLayer.lineCap = .round
        layer.addSublayer(trackLayer)

        for bloom: CAGradientLayer in [pulseBloomLayer, headBloomLayer] {
            bloom.type = .radial
            bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloom.endPoint = CGPoint(x: 1, y: 1)
            bloom.locations = [0, 0.12, 0.42, 1]
        }
        for core: CALayer in [pulseCoreLayer, headCoreLayer] {
            core.shadowOpacity = 1
            core.shadowOffset = .zero
        }

        flareLayer.type = .radial
        flareLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        flareLayer.endPoint = CGPoint(x: 1, y: 1)
        flareLayer.locations = [0, 0.2, 0.55, 1]
        flareLayer.opacity = 0

        // The pulse sits below the head so it visibly slides underneath and
        // into it as they merge; the flare sits above both.
        pulseOrbitLayer.addSublayer(pulseBloomLayer)
        pulseOrbitLayer.addSublayer(pulseCoreLayer)
        pulseOrbitLayer.opacity = 0
        orbitLayer.addSublayer(pulseOrbitLayer)
        orbitLayer.addSublayer(headBloomLayer)
        orbitLayer.addSublayer(headCoreLayer)
        orbitLayer.addSublayer(flareLayer)
        layer.addSublayer(orbitLayer)

        if hidesWhenStopped { isHidden = true }
        applyColors()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: Self, _: UITraitCollection) in self.applyColors()
        }
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    // MARK: Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }

    private var ringRadius: CGFloat {
        min(bounds.width, bounds.height) / 2 * Self.ringScale
    }

    private func layoutLayers() {
        let radius = ringRadius
        guard radius > 0 else { return }
        // Traits can settle after init — an ancestor applying the sky override
        // before this view is in a hierarchy resolves colours here for the first
        // time. Without this a spinner built inside a freshly-presented child
        // keeps the palette of whatever sky was current at `init`.
        applyColors()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Everything rides the top of the ring; the orbit rotation carries it
        // around from there.
        let head = CGPoint(x: center.x, y: center.y - radius)
        let diameter = radius * 2
        let coreDiameter = max(2.2, min(3.4, diameter * 0.16))
        // Keep the scroll indicator's bloom-to-core ratio, but never let the
        // halo outgrow its own ring: on a 20pt spinner that ratio alone is what
        // turns a point of light into a blob.
        let bloomDiameter = min(coreDiameter * Self.bloomToCore, diameter * 1.15)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.frame = bounds
        trackLayer.lineWidth = max(1, min(MoonHorizonStyle.litLineWidth, diameter * 0.075))
        trackLayer.path = UIBezierPath(
            arcCenter: center, radius: radius,
            startAngle: 0, endAngle: .pi * 2, clockwise: true).cgPath

        for orbit: CALayer in [orbitLayer, pulseOrbitLayer] {
            orbit.frame = bounds
        }
        for bloom: CAGradientLayer in [headBloomLayer, pulseBloomLayer] {
            bloom.bounds = CGRect(x: 0, y: 0, width: bloomDiameter, height: bloomDiameter)
            bloom.position = head
        }
        headCoreLayer.bounds = CGRect(x: 0, y: 0, width: coreDiameter, height: coreDiameter)
        headCoreLayer.cornerRadius = coreDiameter / 2
        headCoreLayer.position = head
        headCoreLayer.shadowRadius = coreDiameter
        // The pulse is the head's dimmer, slightly smaller twin.
        let pulseCoreDiameter = coreDiameter * 0.92
        pulseCoreLayer.bounds = CGRect(
            x: 0, y: 0, width: pulseCoreDiameter, height: pulseCoreDiameter)
        pulseCoreLayer.cornerRadius = pulseCoreDiameter / 2
        pulseCoreLayer.position = head
        pulseCoreLayer.shadowRadius = pulseCoreDiameter * 0.8

        let flareDiameter = bloomDiameter * Self.flareToBloom
        flareLayer.bounds = CGRect(x: 0, y: 0, width: flareDiameter, height: flareDiameter)
        flareLayer.position = head
        CATransaction.commit()
    }

    // MARK: Colours

    private func applyColors() {
        let traits = traitCollection
        let sunlight = color.resolvedColor(with: traits)
        let core = MoonHorizonStyle.sunCore.resolvedColor(with: traits)

        trackLayer.strokeColor = sunlight.withAlphaComponent(Self.trackAlpha).cgColor
        headBloomLayer.colors = [
            core.cgColor,
            core.withAlphaComponent(MoonHorizonStyle.headBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.headBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        headCoreLayer.backgroundColor = core.cgColor
        headCoreLayer.shadowColor = core.cgColor
        pulseBloomLayer.colors = [
            core.cgColor,
            core.withAlphaComponent(MoonHorizonStyle.pulseBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.pulseBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        pulseCoreLayer.backgroundColor = core.cgColor
        pulseCoreLayer.shadowColor = core.cgColor
        flareLayer.colors = [
            core.cgColor,
            core.withAlphaComponent(0.85).cgColor,
            sunlight.withAlphaComponent(0.35).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
    }

    // MARK: Animation lifecycle

    public func startAnimating() {
        isAnimating = true
        if hidesWhenStopped { isHidden = false }
        addAnimationsIfPossible()
    }

    public func stopAnimating() {
        isAnimating = false
        removeAnimations()
        if hidesWhenStopped { isHidden = true }
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            removeAnimations()
        } else if isAnimating {
            addAnimationsIfPossible()
        }
    }

    private func addAnimationsIfPossible() {
        guard window != nil, orbitLayer.animation(forKey: Self.orbitKey) == nil else { return }
        layoutLayers()
        // Under Reduce Motion the head simply rests at the top of the ring.
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        addHeadOrbit()
        addPulseCycle()
    }

    /// The head's endless lap, at a pace that swells and eases twice around.
    private func addHeadOrbit() {
        let orbit = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        orbit.values = Self.lapAngles(
            swing: Self.headSpeedSwing, speedCycles: Self.headSpeedCycles)
        orbit.calculationMode = .cubic
        orbit.duration = Self.lapDuration
        orbit.repeatCount = .infinity
        orbit.isRemovedOnCompletion = false
        orbitLayer.add(orbit, forKey: Self.orbitKey)
    }

    /// One pulse cycle: a dimmer point separates from the head, laps the ring
    /// once relative to it, and merges back in a flare — then rests until the
    /// next cycle. Rotating the pulse's own frame *inside* the orbit means it
    /// always departs from, and returns to, exactly where the head is.
    private func addPulseCycle() {
        let travel = CGFloat(Self.pulseTravelDuration / Self.pulseCycleDuration)

        let lap = Self.lapAngles(swing: Self.pulseSpeedSwing, speedCycles: 1)
        let sweep = CAKeyframeAnimation(keyPath: "transform.rotation.z")
        sweep.values = lap + [lap[lap.count - 1]]
        sweep.keyTimes =
            (0..<lap.count).map {
                NSNumber(value: Double(CGFloat($0) / CGFloat(lap.count - 1) * travel))
            } + [1]
        sweep.calculationMode = .cubic
        // Grouped animations need their own duration; a sub-animation left at
        // the default snaps instead of playing across the group.
        sweep.duration = Self.pulseCycleDuration

        // Fade in as it separates, out again just before it arrives, so the
        // merge itself is carried by the flare rather than a hard landing.
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 1, 1, 0, 0]
        glow.keyTimes = [
            0, NSNumber(value: Double(travel * 0.10)), NSNumber(value: Double(travel * 0.88)),
            NSNumber(value: Double(travel)), 1,
        ]
        glow.duration = Self.pulseCycleDuration

        let cycle = CAAnimationGroup()
        cycle.animations = [sweep, glow]
        cycle.duration = Self.pulseCycleDuration
        cycle.repeatCount = .infinity
        cycle.isRemovedOnCompletion = false
        pulseOrbitLayer.add(cycle, forKey: Self.pulseKey)

        addMergeFlare(mergesAt: travel)
    }

    private func addMergeFlare(mergesAt merge: CGFloat) {
        let cycle = CGFloat(Self.pulseCycleDuration)
        let start = merge - CGFloat(Self.flareLead) / cycle
        let span = CGFloat(Self.flareDuration) / cycle
        let keyTimes: [NSNumber] = [
            0, NSNumber(value: Double(start)), NSNumber(value: Double(start + span * 0.35)),
            NSNumber(value: Double(start + span)), 1,
        ]

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 0, 1, 0, 0]
        flash.keyTimes = keyTimes
        flash.duration = Self.pulseCycleDuration

        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [0.7, 0.7, 1.2, 1.35, 1.35]
        swell.keyTimes = keyTimes
        swell.duration = Self.pulseCycleDuration

        let group = CAAnimationGroup()
        group.animations = [flash, swell]
        group.duration = Self.pulseCycleDuration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flareLayer.add(group, forKey: Self.flareKey)
    }

    /// Angles for one full lap whose speed is *not* constant, sampled densely
    /// enough that Core Animation's interpolation between samples is
    /// indistinguishable from the continuous curve:
    ///
    ///     θ(t)  = 2π·t + (swing / cycles)·sin(2π·cycles·t)
    ///     θ'(t) = 2π·(1 + swing·cos(2π·cycles·t))
    ///
    /// With an integral `speedCycles` the lap both ends where it began *and*
    /// ends at the speed it began, so an infinitely repeating orbit is seamless.
    /// A positive `swing` leaves fast and arrives fast; a negative one leaves
    /// and arrives slowly, hurrying through the middle.
    private static func lapAngles(
        swing: CGFloat, speedCycles: CGFloat, samples: Int = 60
    ) -> [NSNumber] {
        (0...samples).map { index in
            let t = CGFloat(index) / CGFloat(samples)
            let angle = 2 * .pi * t + (swing / speedCycles) * sin(2 * .pi * speedCycles * t)
            return NSNumber(value: Double(angle))
        }
    }

    private func removeAnimations() {
        [orbitLayer, pulseOrbitLayer, flareLayer].forEach { $0.removeAllAnimations() }
    }

    // MARK: Completion

    /// The login cover's small success beat: the ring and its lights fade out
    /// as a white-hot checkmark draws itself in their place.
    public func resolveToCheckmark(completion: @escaping () -> Void) {
        guard isAnimating else { completion(); return }
        isAnimating = false
        removeAnimations()

        let radius = ringRadius
        let rect = CGRect(
            x: bounds.midX - radius * 0.62, y: bounds.midY - radius * 0.62,
            width: radius * 1.24, height: radius * 1.24)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))

        let check = CAShapeLayer()
        check.path = path.cgPath
        check.fillColor = nil
        check.strokeColor = MoonHorizonStyle.sunCore.resolvedColor(with: traitCollection).cgColor
        check.lineWidth = max(2, side * 0.075)
        check.lineCap = .round
        check.lineJoin = .round
        check.strokeEnd = 0
        layer.addSublayer(check)

        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        fade.duration = 0.16
        [trackLayer, orbitLayer].forEach {
            $0.add(fade, forKey: "horizonFade")
            $0.opacity = 0
        }

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.32
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        check.strokeEnd = 1
        check.add(draw, forKey: "checkDraw")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.54) { completion() }
    }

    private static let orbitKey = "horizonHeadOrbit"
    private static let pulseKey = "horizonPulseCycle"
    private static let flareKey = "horizonMergeFlare"
}
