//
//  EclipseHorizonSpinnerView.swift
//  LunaDesignSystem
//
//  Luna's shared indeterminate activity treatment. A black moon is ringed by
//  the same dim horizon, dawn glow, and white-hot bloom used by the determinate
//  moon-horizon progress bar. The head light makes a continuous orbit; a second
//  light periodically leaves it, takes one counter-clockwise lap at a varied
//  pace, and resolves in a small merge flare.
//

import QuartzCore
import UIKit
import LunaModels

/// An indeterminate eclipse-horizon activity indicator. It deliberately has
/// the same small API as `UIActivityIndicatorView`, so it can be used in every
/// app and extension without host-specific animation work.
public final class EclipseHorizonSpinnerView: UIView {

    private let side: CGFloat
    private let moonLayer = CAShapeLayer()
    private let horizonLayer = CAShapeLayer()
    private let trailingGlowLayer = CAShapeLayer()
    private let headContainer = CALayer()
    private let headBloomLayer = CAGradientLayer()
    private let headCoreLayer = CALayer()
    private let pulseBloomLayer = CAGradientLayer()
    private let pulseCoreLayer = CALayer()
    private let mergeFlareLayer = CAGradientLayer()

    /// The point's halo uses the horizon palette. Setting `color` tints that
    /// halo while keeping its white-hot core, just like a lunar horizon head.
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
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = L10n.string("Loading")

        moonLayer.fillColor = UIColor.black.cgColor
        layer.addSublayer(moonLayer)

        horizonLayer.fillColor = nil
        horizonLayer.lineCap = .round
        horizonLayer.lineWidth = 1.15
        layer.addSublayer(horizonLayer)

        trailingGlowLayer.fillColor = nil
        trailingGlowLayer.lineCap = .round
        trailingGlowLayer.lineWidth = MoonHorizonStyle.skyGlowLineWidth
        trailingGlowLayer.strokeStart = 0.68
        trailingGlowLayer.strokeEnd = 0.995
        trailingGlowLayer.shadowRadius = 2
        layer.addSublayer(trailingGlowLayer)
        layer.addSublayer(headContainer)

        [headBloomLayer, pulseBloomLayer, mergeFlareLayer].forEach {
            $0.type = .radial
            $0.startPoint = CGPoint(x: 0.5, y: 0.5)
            $0.endPoint = CGPoint(x: 1, y: 1)
            $0.locations = [0, 0.12, 0.42, 1]
        }
        headContainer.addSublayer(headBloomLayer)
        headContainer.addSublayer(headCoreLayer)
        layer.addSublayer(pulseBloomLayer)
        layer.addSublayer(pulseCoreLayer)
        layer.addSublayer(mergeFlareLayer)

        if hidesWhenStopped { isHidden = true }
        applyColors()
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutLayers()
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyColors()
        }
    }

    private var circleRect: CGRect {
        let inset = max(2, min(bounds.width, bounds.height) * 0.13)
        let side = max(0, min(bounds.width, bounds.height) - inset * 2)
        return CGRect(
            x: bounds.midX - side / 2, y: bounds.midY - side / 2,
            width: side, height: side)
    }

    private var orbitRadius: CGFloat { circleRect.width / 2 }

    private func layoutLayers() {
        let circle = circleRect
        guard !circle.isEmpty else { return }
        let path = UIBezierPath(ovalIn: circle).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        moonLayer.path = path
        moonLayer.frame = bounds
        horizonLayer.path = path
        horizonLayer.frame = bounds
        trailingGlowLayer.path = path
        trailingGlowLayer.frame = bounds

        // The moving head is a radial bloom centered at the top of its own
        // container; a container rotation keeps the bloom's geometry crisp.
        let headSize = max(26, circle.width * 0.82)
        headContainer.frame = bounds
        headBloomLayer.frame = CGRect(
            x: bounds.midX - headSize / 2, y: circle.minY - headSize / 2,
            width: headSize, height: headSize)
        headCoreLayer.frame = CGRect(
            x: bounds.midX - 1.7, y: circle.minY - 1.7,
            width: 3.4, height: 3.4)
        headCoreLayer.cornerRadius = 1.7

        let pulseSize = max(22, circle.width * 0.70)
        pulseBloomLayer.bounds = CGRect(x: 0, y: 0, width: pulseSize, height: pulseSize)
        pulseBloomLayer.position = CGPoint(x: bounds.midX, y: circle.minY)
        pulseCoreLayer.bounds = CGRect(x: 0, y: 0, width: 3.1, height: 3.1)
        pulseCoreLayer.cornerRadius = 1.55
        pulseCoreLayer.position = CGPoint(x: bounds.midX, y: circle.minY)

        let flareSize = max(34, circle.width)
        mergeFlareLayer.frame = CGRect(
            x: bounds.midX - flareSize / 2, y: circle.minY - flareSize / 2,
            width: flareSize, height: flareSize)
        CATransaction.commit()
    }

    private func applyColors() {
        let traits = traitCollection
        let sunlight = color.resolvedColor(with: traits)
        let core = MoonHorizonStyle.sunCore.resolvedColor(with: traits)
        moonLayer.fillColor = UIColor.black.cgColor
        horizonLayer.strokeColor = MoonHorizonStyle.darkHorizon(for: traits).cgColor
        trailingGlowLayer.strokeColor = sunlight.withAlphaComponent(0.54).cgColor
        trailingGlowLayer.shadowColor = sunlight.withAlphaComponent(0.30).cgColor

        let bloomColors = [
            core.cgColor,
            core.withAlphaComponent(MoonHorizonStyle.headBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.headBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        headBloomLayer.colors = bloomColors
        headCoreLayer.backgroundColor = core.cgColor
        pulseBloomLayer.colors = [
            core.cgColor,
            core.withAlphaComponent(MoonHorizonStyle.pulseBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.pulseBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        pulseCoreLayer.backgroundColor = core.cgColor
        mergeFlareLayer.colors = [
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
        guard window != nil, headContainer.animation(forKey: Self.headOrbitKey) == nil else { return }
        layoutLayers()
        if UIAccessibility.isReduceMotionEnabled { return }

        // The first point loops without interruption. The glow tail is attached
        // to that same orbit, so it reads as horizon light gathering behind it.
        let orbitDuration: CFTimeInterval = 2.4
        let headOrbit = CABasicAnimation(keyPath: "transform.rotation.z")
        headOrbit.fromValue = 0
        headOrbit.toValue = CGFloat.pi * 2
        headOrbit.duration = orbitDuration
        headOrbit.repeatCount = .infinity
        headOrbit.timingFunction = CAMediaTimingFunction(name: .linear)
        headOrbit.isRemovedOnCompletion = false
        headContainer.add(headOrbit, forKey: Self.headOrbitKey)

        let tailOrbit = headOrbit.copy() as! CABasicAnimation
        trailingGlowLayer.add(tailOrbit, forKey: Self.tailOrbitKey)

        addPulseAnimation(orbitDuration: orbitDuration)
    }

    private func addPulseAnimation(orbitDuration: CFTimeInterval) {
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = orbitRadius
        guard radius > 0 else { return }
        let travelDuration = orbitDuration
        let cycleDuration = orbitDuration * 2
        let points = [
            point(angle: -.pi / 2, center: center, radius: radius),
            point(angle: -.pi * 0.70, center: center, radius: radius),
            point(angle: -.pi * 1.05, center: center, radius: radius),
            point(angle: -.pi * 1.32, center: center, radius: radius),
            point(angle: -.pi * 1.67, center: center, radius: radius),
            point(angle: -.pi * 2.50, center: center, radius: radius),
        ]

        // A deliberately uneven set of distances in time: the released point
        // drifts away, races through the lower limb, then eases back to merge.
        let path = CAKeyframeAnimation(keyPath: "position")
        path.values = points.map { NSValue(cgPoint: $0) }
        path.keyTimes = [0, 0.17, 0.38, 0.64, 0.86, 1]
        path.duration = travelDuration
        path.timingFunctions = [
            CAMediaTimingFunction(name: .easeInEaseOut),
            CAMediaTimingFunction(controlPoints: 0.18, 0.84, 0.30, 1),
            CAMediaTimingFunction(controlPoints: 0.76, 0, 0.92, 0.35),
            CAMediaTimingFunction(name: .easeInEaseOut),
        ]

        let opacity = CAKeyframeAnimation(keyPath: "opacity")
        opacity.values = [0, 1, 1, 1, 1, 0]
        opacity.keyTimes = [0, 0.06, 0.13, 0.79, 0.94, 1]
        opacity.duration = travelDuration

        let pulseGroup = CAAnimationGroup()
        pulseGroup.animations = [path, opacity]
        pulseGroup.duration = travelDuration
        pulseGroup.beginTime = 0

        let group = CAAnimationGroup()
        group.animations = [pulseGroup]
        group.duration = cycleDuration
        group.repeatCount = .infinity
        group.isRemovedOnCompletion = false
        pulseBloomLayer.add(group, forKey: Self.pulseOrbitKey)
        pulseCoreLayer.add(group.copy() as! CAAnimationGroup, forKey: Self.pulseCoreKey)

        let flare = CAKeyframeAnimation(keyPath: "opacity")
        flare.values = [0, 0, 0, 1, 0, 0]
        flare.keyTimes = [0, 0.83, 0.91, 0.96, 1, 1]
        flare.duration = cycleDuration
        flare.repeatCount = .infinity
        flare.isRemovedOnCompletion = false
        mergeFlareLayer.add(flare, forKey: Self.mergeKey)
    }

    private func point(angle: CGFloat, center: CGPoint, radius: CGFloat) -> CGPoint {
        CGPoint(x: center.x + cos(angle) * radius, y: center.y + sin(angle) * radius)
    }

    private func removeAnimations() {
        [headContainer, trailingGlowLayer, pulseBloomLayer, pulseCoreLayer, mergeFlareLayer].forEach {
            $0.removeAllAnimations()
        }
    }

    // MARK: Completion

    /// Preserves the login cover's small success beat without retaining the old
    /// grid/checkmark behaviour: the horizon fades into a centered checkmark.
    public func resolveToCheckmark(completion: @escaping () -> Void) {
        guard isAnimating else { completion(); return }
        isAnimating = false
        removeAnimations()
        let check = CAShapeLayer()
        let rect = circleRect.insetBy(dx: circleRect.width * 0.25, dy: circleRect.height * 0.25)
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.midX - rect.width * 0.08, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
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
        [moonLayer, horizonLayer, trailingGlowLayer, headContainer].forEach {
            $0.add(fade, forKey: "eclipseFade")
            $0.opacity = 0
        }
        check.opacity = 1

        let draw = CABasicAnimation(keyPath: "strokeEnd")
        draw.fromValue = 0
        draw.toValue = 1
        draw.duration = UIAccessibility.isReduceMotionEnabled ? 0.16 : 0.32
        draw.timingFunction = CAMediaTimingFunction(name: .easeOut)
        check.strokeEnd = 1
        check.add(draw, forKey: "checkDraw")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.54) { completion() }
    }

    private static let headOrbitKey = "eclipseHeadOrbit"
    private static let tailOrbitKey = "eclipseTailOrbit"
    private static let pulseOrbitKey = "eclipsePulseOrbit"
    private static let pulseCoreKey = "eclipsePulseCore"
    private static let mergeKey = "eclipseMergeFlare"
}
