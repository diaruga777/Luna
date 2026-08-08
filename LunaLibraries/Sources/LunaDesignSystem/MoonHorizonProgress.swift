//
//  MoonHorizonProgress.swift
//  Luna
//

import SwiftUI
import UIKit
import LunaModels

/// The shared geometry + palette for the "moon horizon" progress treatment: a
/// full-width, very slightly curved lunar horizon. The sun's first light creeps
/// along it from left to right as progress advances — a single brilliant point
/// marks the head (the sun just peeking over the horizon), a faint pre-dawn glow
/// trails it to the left, and the horizon ahead (to the right) stays dark.
/// Stylized, not hyperrealistic.
public enum MoonHorizonStyle {

    /// A tempered form of the current app's identity colour. The gradients and
    /// low-alpha bloom keep it atmospheric rather than reading as a solid stripe.
    public static let sunlight = LunaSurfacePalette.progressAccent
    /// The white-hot center of the sun point itself.
    public static let sunCore = UIColor { traits in
        traits.lunaSky == .night
            ? UIColor.white
            : UIColor(red: 1.00, green: 0.97, blue: 0.92, alpha: 1)
    }

    /// The unlit horizon ahead of the sun — barely-there in either appearance.
    public static func darkHorizon(for traits: UITraitCollection) -> UIColor {
        let alpha: CGFloat = traits.lunaSky == .night ? 0.30 : 0.28
        return LunaColors.primaryText.resolvedColor(with: traits).withAlphaComponent(alpha)
    }

    /// The faint suggestion of the moon's surface below the horizon line.
    public static func surface(for traits: UITraitCollection) -> UIColor {
        LunaColors.primaryText.resolvedColor(with: traits).withAlphaComponent(0.05)
    }

    /// Control points of the horizon curve: a quadratic Bézier spanning the full
    /// width, apex slightly above the endpoints so the curve reads as the limb of
    /// a large body — very, very slight.
    public static func horizonControlPoints(
        in rect: CGRect
    ) -> (start: CGPoint, control: CGPoint, end: CGPoint) {
        // Leave headroom above the curve for the sun's glow, and a little floor
        // below for the surface fill.
        let rise = min(rect.height * 0.30, 6)
        let baseY = rect.maxY - max(rect.height * 0.18, 3)
        let start = CGPoint(x: rect.minX, y: baseY)
        let end = CGPoint(x: rect.maxX, y: baseY)
        // A quadratic curve passes halfway between its control point and the
        // chord at t = 0.5, so doubling the rise puts the apex at `baseY - rise`.
        let control = CGPoint(x: rect.midX, y: baseY - rise * 2)
        return (start, control, end)
    }

    /// The horizon line as a path.
    public static func horizonPath(in rect: CGRect) -> CGPath {
        let (start, control, end) = horizonControlPoints(in: rect)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        return path
    }

    /// The closed region below the horizon (the moon's surface), for a faint fill.
    public static func surfacePath(in rect: CGRect) -> CGPath {
        let (start, control, end) = horizonControlPoints(in: rect)
        let path = CGMutablePath()
        path.move(to: start)
        path.addQuadCurve(to: end, control: control)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }

    /// The point on the horizon for a progress fraction. Uses the Bézier
    /// parameter directly — the curve is shallow enough that parameter and
    /// arc-length fractions are visually identical, which keeps the head in
    /// step with `strokeEnd` trimming.
    public static func point(atFraction fraction: CGFloat, in rect: CGRect) -> CGPoint {
        let t = min(1, max(0, fraction))
        let (start, control, end) = horizonControlPoints(in: rect)
        let mt = 1 - t
        return CGPoint(
            x: mt * mt * start.x + 2 * mt * t * control.x + t * t * end.x,
            y: mt * mt * start.y + 2 * mt * t * control.y + t * t * end.y)
    }

    // Shared brightness ramp for the trailing glow: nearly nothing at the far
    // left, gathering toward the head, full strength only right behind the sun.
    // (peakAlpha at the head; midAlpha a bit over halfway back.)
    static let litLineWidth: CGFloat = 1.4
    static let litMidAlpha: CGFloat = 0.30
    static let skyGlowLineWidth: CGFloat = 7
    static let skyGlowMidAlpha: CGFloat = 0.07
    static let skyGlowPeakAlpha: CGFloat = 0.40
    /// Where (as a fraction of the lit stretch) the ramp passes through midAlpha.
    static let rampMid: CGFloat = 0.55

    // The sun point and the traveling pulse. headBloom{Inner,Outer}Alpha are brighter
    // than pulseBloom{Inner,Outer}Alpha, so the head reads as more lit than the
    // traveling pulse; the merge flare briefly outshines both.
    static let headBloomInnerAlpha: CGFloat = 0.70
    static let headBloomOuterAlpha: CGFloat = 0.22
    static let pulseBloomInnerAlpha: CGFloat = 0.55
    static let pulseBloomOuterAlpha: CGFloat = 0.16
    static let pulseCycleDuration: TimeInterval = 2.6
    /// The pulse's speed, in fractions of the bar's width per second, is
    /// `pulseBaseSpeed + pulseAcceleration × seconds alive` — a function of AGE,
    /// not of how much of the lit stretch is left. That distinction is the whole
    /// point: a fixed-duration animation aimed at where the head was when it
    /// launched has to swallow every point the head gains afterwards in whatever
    /// time remains, which is felt as a crawl followed by a teleport. Chasing at
    /// an accelerating speed instead means the pulse always closes the real gap,
    /// and the acceleration is spread over the whole travel. Tuned so a pulse
    /// crossing half the bar takes ~1.1s and arrives ~4× faster than it left.
    static let pulseBaseSpeed: CGFloat = 0.18
    static let pulseAcceleration: CGFloat = 0.55
    /// A pulse that somehow never catches the head gives up rather than living
    /// forever. Unreachable in practice — the head is bounded at 1 and the pulse
    /// isn't — so this is a backstop, not a timing knob.
    static let pulseMaximumLifetime: TimeInterval = 8
    /// Fade-in at launch, over the first of these seconds of travel.
    static let pulseFadeDuration: TimeInterval = 0.15
    /// How close (in points) the pulse gets before the merge starts: the flare
    /// lights and the pulse dissolves into the sun over the last of the gap.
    /// Halved down on a lit stretch too short to spare it.
    static let pulseMergeDistance: CGFloat = 10
    static let pulseFlareDuration: TimeInterval = 0.45
    /// Below this fraction there's no lit stretch worth traveling.
    static let pulseMinimumFraction: CGFloat = 0.05
    /// SwiftUI/WidgetKit only. That renderer re-derives the pulse's position from
    /// *live* progress on every render (`travel × progress`), so a fixed-length
    /// keyframe track can't fall behind the head the way a UIKit path animation
    /// baked against a snapshot could.
    static let pulseTravelDuration: TimeInterval = 1.1
}

/// The traveling pulse's kinematics, kept out of the view so the chase can be
/// reasoned about — and tested — without a display link. It knows only how long
/// it has been alive; where it is going is the caller's business, re-read every
/// frame.
struct MoonHorizonPulseChase {

    /// How far along the bar the pulse is, as a fraction of its width.
    private(set) var fraction: CGFloat = 0
    /// Seconds since launch. The speed is a function of this and nothing else.
    private(set) var age: TimeInterval = 0

    /// Fractions of the bar's width per second, right now.
    var speed: CGFloat {
        MoonHorizonStyle.pulseBaseSpeed + MoonHorizonStyle.pulseAcceleration * CGFloat(age)
    }

    mutating func advance(by elapsed: TimeInterval) {
        age += max(0, elapsed)
        fraction = min(1, fraction + speed * CGFloat(max(0, elapsed)))
    }
}

// MARK: - UIKit

/// A drop-in replacement for a determinate `UIProgressView` drawn as the moon
/// horizon: dark limb ahead, the faint glow of pre-dawn light gathering behind,
/// and one brilliant point where the sun peeks over the horizon at the head of
/// progress. Spans whatever width it's given. While in a window (and progress
/// is mid-flight), a dimmer point of light periodically sweeps in from the left
/// and merges with the sun in a brief flare — a heartbeat that shows something
/// is happening even when the fraction itself isn't moving. That pulse is a
/// per-frame chase rather than a Core Animation path: it re-reads the sun's
/// drawn position every frame and speeds up the longer it has been traveling,
/// so it merges where the sun actually is on a bar whose progress is still
/// climbing. Skipped under Reduce Motion.
public final class MoonHorizonProgressBar: UIView {

    private let surfaceLayer = CAShapeLayer()
    private let darkHorizonLayer = CAShapeLayer()
    /// The wide, soft pre-dawn glow along the lit stretch: a horizontal gradient
    /// (faint → bright toward the head) masked to the horizon curve.
    private let skyGlowGradient = CAGradientLayer()
    private let skyGlowMask = CAShapeLayer()
    /// The thin illumination line itself, same gradient ramp but tighter.
    private let litGradient = CAGradientLayer()
    private let litMask = CAShapeLayer()
    /// The sun: a steep radial bloom around a white-hot core.
    private let headBloomLayer = CAGradientLayer()
    private let headCoreLayer = CALayer()
    /// The traveling pulse: a second, dimmer sun point that periodically sweeps
    /// in from the left edge and merges with the head.
    private let pulseLayer = CALayer()
    private let pulseBloomLayer = CAGradientLayer()
    private let pulseCoreLayer = CALayer()
    /// The brief burst where pulse and head merge, brighter than either alone.
    private let flareLayer = CAGradientLayer()
    private var pulseTimer: Timer?
    /// The in-flight pulse is stepped frame by frame rather than handed to Core
    /// Animation, so every frame can re-read where the head actually is.
    private var pulseDisplayLink: CADisplayLink?
    private var pulse = MoonHorizonPulseChase()
    private var pulseLastTick: CFTimeInterval = 0
    private var pulseDidFlare = false
    /// Whether the pulse has ever been a real distance BEHIND the drawn head.
    /// Until it has, "the pulse has caught the head" means the head hasn't
    /// arrived yet — a bar still easing toward a fraction set a moment ago —
    /// and merging on that would flare at the left edge the instant the pulse
    /// launched.
    private var pulseDidChase = false

    public private(set) var progress: Float = 0
    /// Whether an activity point periodically travels from the start to the
    /// progress head. Download surfaces leave this enabled; playback progress
    /// bars disable it because their changing fraction already conveys motion.
    public var showsActivityPulse = true {
        didSet {
            guard showsActivityPulse != oldValue else { return }
            updatePulseTimer()
            if !showsActivityPulse {
                endPulse()
                flareLayer.removeAllAnimations()
            }
        }
    }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = L10n.string("CardDeck_progressAccessibilityLabel")

        surfaceLayer.strokeColor = nil
        layer.addSublayer(surfaceLayer)

        darkHorizonLayer.fillColor = nil
        darkHorizonLayer.lineCap = .round
        darkHorizonLayer.lineWidth = 1
        layer.addSublayer(darkHorizonLayer)

        for (gradient, mask, lineWidth): (CAGradientLayer, CAShapeLayer, CGFloat) in [
            (skyGlowGradient, skyGlowMask, MoonHorizonStyle.skyGlowLineWidth),
            (litGradient, litMask, MoonHorizonStyle.litLineWidth),
        ] {
            mask.fillColor = nil
            mask.strokeColor = UIColor.white.cgColor
            mask.lineCap = .round
            mask.lineWidth = lineWidth
            mask.strokeEnd = 0
            gradient.startPoint = CGPoint(x: 0, y: 0.5)
            gradient.endPoint = CGPoint(x: 1, y: 0.5)
            gradient.mask = mask
            layer.addSublayer(gradient)
        }

        let bloomDiameter: CGFloat = 26
        let coreDiameter: CGFloat = 3

        // The pulse sits below the head so it visibly slides underneath and
        // into the sun as they merge.
        for bloom: CAGradientLayer in [pulseBloomLayer, headBloomLayer] {
            bloom.type = .radial
            bloom.bounds = CGRect(x: 0, y: 0, width: bloomDiameter, height: bloomDiameter)
            bloom.startPoint = CGPoint(x: 0.5, y: 0.5)
            bloom.endPoint = CGPoint(x: 1, y: 1)
            bloom.locations = [0, 0.12, 0.42, 1]
        }
        for core: CALayer in [pulseCoreLayer, headCoreLayer] {
            core.bounds = CGRect(x: 0, y: 0, width: coreDiameter, height: coreDiameter)
            core.cornerRadius = coreDiameter / 2
            core.shadowOpacity = 1
            core.shadowRadius = 2.5
            core.shadowOffset = .zero
        }
        headCoreLayer.shadowRadius = 3

        pulseBloomLayer.position = .zero
        pulseCoreLayer.position = .zero
        pulseLayer.addSublayer(pulseBloomLayer)
        pulseLayer.addSublayer(pulseCoreLayer)
        pulseLayer.opacity = 0
        layer.addSublayer(pulseLayer)

        layer.addSublayer(headBloomLayer)
        layer.addSublayer(headCoreLayer)

        flareLayer.type = .radial
        flareLayer.bounds = CGRect(x: 0, y: 0, width: 34, height: 34)
        flareLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        flareLayer.endPoint = CGPoint(x: 1, y: 1)
        flareLayer.locations = [0, 0.2, 0.55, 1]
        flareLayer.opacity = 0
        layer.addSublayer(flareLayer)

        updateAppearanceColors()
        registerForTraitChanges([LunaSkyTrait.self]) {
            (self: Self, _: UITraitCollection) in
            self.updateAppearanceColors()
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        pulseTimer?.invalidate()
        pulseDisplayLink?.invalidate()
    }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 20)
    }

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        updatePulseTimer()
    }

    private func updatePulseTimer() {
        if window == nil || !showsActivityPulse {
            pulseTimer?.invalidate()
            pulseTimer = nil
            endPulse()
        } else if pulseTimer == nil {
            let timer = Timer.scheduledTimer(
                withTimeInterval: MoonHorizonStyle.pulseCycleDuration, repeats: true
            ) { [weak self] _ in
                self?.firePulse()
            }
            timer.tolerance = 0.25
            pulseTimer = timer
        }
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Traits can settle after init (e.g. overrideUserInterfaceStyle applied by
        // an ancestor before this view is in a window) — re-resolve here too.
        updateAppearanceColors()
        let horizon = MoonHorizonStyle.horizonPath(in: bounds)
        surfaceLayer.path = MoonHorizonStyle.surfacePath(in: bounds)
        darkHorizonLayer.path = horizon
        skyGlowGradient.frame = bounds
        litGradient.frame = bounds
        skyGlowMask.frame = bounds
        litMask.frame = bounds
        skyGlowMask.path = horizon
        litMask.path = horizon
        positionHead()
        CATransaction.commit()
    }

    public func setProgress(_ value: Float, animated: Bool) {
        let clamped = min(1, max(0, value))
        progress = clamped
        accessibilityValue = "\(Int(clamped * 100))%"
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.3)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        litMask.strokeEnd = CGFloat(clamped)
        skyGlowMask.strokeEnd = CGFloat(clamped)
        // The curve is shallow enough that animating the position straight between
        // nearby horizon points is indistinguishable from tracing the curve.
        positionHead()
        CATransaction.commit()
    }

    /// Whether a pulse can be shown at all right now — a pulse already in flight
    /// is abandoned the moment this stops holding.
    private var pulseIsPresentable: Bool {
        showsActivityPulse && window != nil && !isHidden && alpha > 0.01
            && bounds.width > 0 && !UIAccessibility.isReduceMotionEnabled
    }

    /// Where the sun is *on screen* right now, as a fraction of the bar's width.
    /// Not `progress`: that value can be a third of a second ahead of the drawn
    /// point while `setProgress(animated:)` eases toward it, and merging with a
    /// head that isn't there yet is as visible as merging with one that has
    /// already moved on. `x` is exactly linear in this curve's Bézier parameter
    /// (the control point sits at the horizontal midpoint), so a fraction of the
    /// width and a fraction of the path are the same number.
    private var presentedHeadFraction: CGFloat {
        guard bounds.width > 0 else { return 0 }
        let x = (headCoreLayer.presentation() ?? headCoreLayer).position.x
        return min(1, max(0, (x - bounds.minX) / bounds.width))
    }

    /// One pulse cycle: a dim point of light launches from the left edge and
    /// accelerates along the lit stretch until it catches the sun, merging into
    /// it in a flare. It chases the head rather than a snapshot of it, so a bar
    /// whose progress advances mid-flight still merges where the sun actually is.
    private func firePulse() {
        guard pulseDisplayLink == nil, pulseIsPresentable,
            CGFloat(progress) > MoonHorizonStyle.pulseMinimumFraction, progress < 1
        else { return }

        pulse = MoonHorizonPulseChase()
        pulseDidFlare = false
        pulseDidChase = false
        pulseLastTick = CACurrentMediaTime()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.opacity = 0
        pulseLayer.position = MoonHorizonStyle.point(atFraction: 0, in: bounds)
        CATransaction.commit()

        let link = CADisplayLink(target: self, selector: #selector(advancePulse(_:)))
        link.add(to: .main, forMode: .common)
        pulseDisplayLink = link
    }

    @objc private func advancePulse(_ link: CADisplayLink) {
        guard pulseIsPresentable else { return endPulse() }

        let now = CACurrentMediaTime()
        // Cap the step so a stalled run loop (a modal presentation, a slow frame)
        // doesn't hand the pulse a jump the eye reads as the very artefact this
        // replaced.
        let elapsed = min(max(0, now - pulseLastTick), 1.0 / 15)
        pulseLastTick = now
        pulse.advance(by: elapsed)

        let headFraction = presentedHeadFraction
        let gap = (headFraction - pulse.fraction) * bounds.width
        // On a short lit stretch the full merge distance would be most of the
        // journey, so the pulse would fade before it ever read as traveling.
        let mergeDistance = max(
            1, min(MoonHorizonStyle.pulseMergeDistance, headFraction * bounds.width / 2))

        if gap > mergeDistance { pulseDidChase = true }
        if pulseDidChase, gap <= mergeDistance, !pulseDidFlare {
            pulseDidFlare = true
            fireMergeFlare(at: headFraction)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Clamped to the head so the pulse slides under the sun rather than past it.
        pulseLayer.position = MoonHorizonStyle.point(
            atFraction: min(pulse.fraction, headFraction), in: bounds)
        let fadeIn = min(1, CGFloat(pulse.age / MoonHorizonStyle.pulseFadeDuration))
        let dissolve = pulseDidChase ? min(1, max(0, gap / mergeDistance)) : 1
        pulseLayer.opacity = Float(fadeIn * dissolve)
        CATransaction.commit()

        if (pulseDidChase && gap <= 0) || pulse.age >= MoonHorizonStyle.pulseMaximumLifetime {
            endPulse()
        }
    }

    private func endPulse() {
        pulseDisplayLink?.invalidate()
        pulseDisplayLink = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pulseLayer.opacity = 0
        CATransaction.commit()
    }

    private func fireMergeFlare(at headFraction: CGFloat) {
        guard showsActivityPulse, window != nil, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flareLayer.position = MoonHorizonStyle.point(atFraction: headFraction, in: bounds)
        CATransaction.commit()

        let flash = CAKeyframeAnimation(keyPath: "opacity")
        flash.values = [0, 1, 0]
        flash.keyTimes = [0, 0.35, 1]
        flash.duration = MoonHorizonStyle.pulseFlareDuration

        let swell = CAKeyframeAnimation(keyPath: "transform.scale")
        swell.values = [0.7, 1.2, 1.35]
        swell.keyTimes = [0, 0.35, 1]
        swell.duration = MoonHorizonStyle.pulseFlareDuration

        let group = CAAnimationGroup()
        group.animations = [flash, swell]
        group.duration = MoonHorizonStyle.pulseFlareDuration
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        flareLayer.add(group, forKey: "flare")
    }

    private func positionHead() {
        let head = MoonHorizonStyle.point(atFraction: CGFloat(progress), in: bounds)
        headCoreLayer.position = head
        headBloomLayer.position = head
        // Peak the trailing gradients exactly at the head so the glow gathers
        // toward the sun rather than lighting the whole trail evenly.
        guard bounds.width > 0 else { return }
        let headFraction = head.x / bounds.width
        skyGlowGradient.endPoint = CGPoint(x: headFraction, y: 0.5)
        litGradient.endPoint = CGPoint(x: headFraction, y: 0.5)
    }

    private func updateAppearanceColors() {
        let sunlight = MoonHorizonStyle.sunlight.resolvedColor(with: traitCollection)
        let sunCore = MoonHorizonStyle.sunCore.resolvedColor(with: traitCollection)
        darkHorizonLayer.strokeColor = MoonHorizonStyle.darkHorizon(for: traitCollection).cgColor
        surfaceLayer.fillColor = MoonHorizonStyle.surface(for: traitCollection).cgColor
        let ramp: [NSNumber] = [0, NSNumber(value: Double(MoonHorizonStyle.rampMid)), 1]
        skyGlowGradient.colors = [
            sunlight.withAlphaComponent(0).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.skyGlowMidAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.skyGlowPeakAlpha).cgColor,
        ]
        skyGlowGradient.locations = ramp
        litGradient.colors = [
            sunlight.withAlphaComponent(0.02).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.litMidAlpha).cgColor,
            sunlight.cgColor,
        ]
        litGradient.locations = ramp
        headBloomLayer.colors = [
            sunCore.cgColor,
            sunCore.withAlphaComponent(MoonHorizonStyle.headBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.headBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        headCoreLayer.backgroundColor = sunCore.cgColor
        headCoreLayer.shadowColor = sunCore.cgColor
        pulseBloomLayer.colors = [
            sunCore.cgColor,
            sunCore.withAlphaComponent(MoonHorizonStyle.pulseBloomInnerAlpha).cgColor,
            sunlight.withAlphaComponent(MoonHorizonStyle.pulseBloomOuterAlpha).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        pulseCoreLayer.backgroundColor = sunCore.cgColor
        pulseCoreLayer.shadowColor = sunCore.cgColor
        flareLayer.colors = [
            sunCore.cgColor,
            sunCore.withAlphaComponent(0.85).cgColor,
            sunlight.withAlphaComponent(0.35).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
    }
}

// MARK: - SwiftUI

/// The horizon line as a SwiftUI `Shape`, so it can be trimmed and stroked.
private struct MoonHorizonLine: Shape {
    func path(in rect: CGRect) -> Path {
        Path(MoonHorizonStyle.horizonPath(in: rect))
    }
}

/// The closed surface region below the horizon.
private struct MoonHorizonSurface: Shape {
    func path(in rect: CGRect) -> Path {
        Path(MoonHorizonStyle.surfacePath(in: rect))
    }
}

/// The moon-horizon progress treatment for SwiftUI surfaces (the download Live
/// Activity). Same visual language as `MoonHorizonProgressBar`. Built from plain
/// shapes and gradients so it renders reliably inside WidgetKit.
/// The animatable state of one pulse cycle: where the traveling point is along
/// the lit stretch, how visible it is, and how strong the merge flare is.
private struct MoonPulsePhase {
    var travel: CGFloat = 0
    var glow: CGFloat = 0
    var flare: CGFloat = 0
}

public struct MoonHorizonProgressView: View {
    private let progress: Double
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: Double) {
        self.progress = min(1, max(0, progress))
    }

    public var body: some View {
        let sunlight = Color(MoonHorizonStyle.sunlight)
        let sunCore = Color(MoonHorizonStyle.sunCore)
        let darkHorizonOpacity = colorScheme == .dark ? 0.30 : 0.28
        GeometryReader { geometry in
            let rect = CGRect(origin: .zero, size: geometry.size)
            let head = MoonHorizonStyle.point(atFraction: progress, in: rect)
            let headFraction = rect.width > 0 ? head.x / rect.width : 0
            ZStack {
                // The moon's surface, barely there.
                MoonHorizonSurface()
                    .fill(Color.primary.opacity(0.05))
                // The dark horizon ahead of the sun.
                MoonHorizonLine()
                    .stroke(
                        Color.primary.opacity(darkHorizonOpacity),
                        style: StrokeStyle(lineWidth: 1, lineCap: .round))
                // The wide, soft pre-dawn glow gathering toward the head.
                MoonHorizonLine()
                    .trim(from: 0, to: progress)
                    .stroke(
                        trailingGlow(
                            sunlight, headFraction: headFraction,
                            midAlpha: MoonHorizonStyle.skyGlowMidAlpha,
                            peakAlpha: MoonHorizonStyle.skyGlowPeakAlpha),
                        style: StrokeStyle(
                            lineWidth: MoonHorizonStyle.skyGlowLineWidth, lineCap: .round))
                    .blur(radius: 2)
                // The thin illumination line, brightest just behind the sun.
                MoonHorizonLine()
                    .trim(from: 0, to: progress)
                    .stroke(
                        trailingGlow(
                            sunlight, headFraction: headFraction,
                            midAlpha: MoonHorizonStyle.litMidAlpha, peakAlpha: 1),
                        style: StrokeStyle(
                            lineWidth: MoonHorizonStyle.litLineWidth, lineCap: .round))
                // The sun, just peeking over the horizon: a steep bloom around a
                // white-hot point.
                Circle()
                    .fill(RadialGradient(
                        stops: [
                            .init(color: sunCore, location: 0),
                            .init(
                                color: sunCore.opacity(MoonHorizonStyle.headBloomInnerAlpha),
                                location: 0.12),
                            .init(
                                color: sunlight.opacity(MoonHorizonStyle.headBloomOuterAlpha),
                                location: 0.42),
                            .init(color: sunlight.opacity(0), location: 1),
                        ],
                        center: .center, startRadius: 0, endRadius: 13))
                    .frame(width: 26, height: 26)
                    .position(head)
                Circle()
                    .fill(sunCore)
                    .frame(width: 3, height: 3)
                    .shadow(color: sunCore, radius: 1.8)
                    .position(head)
                // The traveling pulse + merge flare. Time-driven, so inside
                // WidgetKit's frozen renders it simply stays at its initial
                // (invisible) phase; in live contexts it sweeps continuously.
                if !reduceMotion, progress > Double(MoonHorizonStyle.pulseMinimumFraction),
                    progress < 1
                {
                    Color.clear
                        .keyframeAnimator(
                            initialValue: MoonPulsePhase(), repeating: true
                        ) { content, phase in
                            content.overlay {
                                pulseAndFlare(
                                    phase: phase, rect: rect, head: head,
                                    sunlight: sunlight, sunCore: sunCore)
                            }
                        } keyframes: { _ in
                            let travel = MoonHorizonStyle.pulseTravelDuration
                            let fade = MoonHorizonStyle.pulseFadeDuration
                            let flare = MoonHorizonStyle.pulseFlareDuration
                            let cycle = MoonHorizonStyle.pulseCycleDuration
                            KeyframeTrack(\MoonPulsePhase.travel) {
                                CubicKeyframe(1, duration: travel)
                                LinearKeyframe(1, duration: cycle - travel)
                            }
                            KeyframeTrack(\MoonPulsePhase.glow) {
                                LinearKeyframe(1, duration: fade)
                                LinearKeyframe(1, duration: travel - 2 * fade)
                                LinearKeyframe(0, duration: fade)
                                LinearKeyframe(0, duration: cycle - travel)
                            }
                            KeyframeTrack(\MoonPulsePhase.flare) {
                                LinearKeyframe(0, duration: travel - fade)
                                LinearKeyframe(1, duration: 0.35 * flare)
                                LinearKeyframe(0, duration: 0.65 * flare)
                                LinearKeyframe(
                                    0, duration: cycle - travel + fade - flare)
                            }
                        }
                }
            }
        }
        .accessibilityElement()
        .accessibilityLabel(L10n.string("CardDeck_progressAccessibilityLabel"))
        .accessibilityValue("\(Int(progress * 100))%")
    }

    /// The traveling pulse (a dimmer sun point, at the head's former
    /// brightness) plus the flare where it merges with the head.
    @ViewBuilder
    private nonisolated func pulseAndFlare(
        phase: MoonPulsePhase, rect: CGRect, head: CGPoint, sunlight: Color, sunCore: Color
    ) -> some View {
        let pulsePoint = MoonHorizonStyle.point(
            atFraction: phase.travel * progress, in: rect)
        Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: sunCore, location: 0),
                    .init(
                        color: sunCore.opacity(MoonHorizonStyle.pulseBloomInnerAlpha),
                        location: 0.12),
                    .init(
                        color: sunlight.opacity(MoonHorizonStyle.pulseBloomOuterAlpha),
                        location: 0.42),
                    .init(color: sunlight.opacity(0), location: 1),
                ],
                center: .center, startRadius: 0, endRadius: 13))
            .frame(width: 26, height: 26)
            .opacity(phase.glow)
            .position(pulsePoint)
        Circle()
            .fill(sunCore)
            .frame(width: 3, height: 3)
            .shadow(color: sunCore, radius: 1.5)
            .opacity(phase.glow)
            .position(pulsePoint)
        Circle()
            .fill(RadialGradient(
                stops: [
                    .init(color: sunCore, location: 0),
                    .init(color: sunCore.opacity(0.85), location: 0.2),
                    .init(color: sunlight.opacity(0.35), location: 0.55),
                    .init(color: sunlight.opacity(0), location: 1),
                ],
                center: .center, startRadius: 0, endRadius: 17))
            .frame(width: 34, height: 34)
            .scaleEffect(0.7 + 0.65 * phase.flare)
            .opacity(phase.flare)
            .position(head)
    }

    /// The brightness ramp behind the sun, expressed over the view's full width:
    /// nearly nothing at the far left, `midAlpha` a bit past halfway along the lit
    /// stretch, `peakAlpha` exactly at the head.
    private func trailingGlow(
        _ sunlight: Color, headFraction: CGFloat, midAlpha: CGFloat, peakAlpha: CGFloat
    ) -> LinearGradient {
        let mid = max(headFraction * MoonHorizonStyle.rampMid, 0.0001)
        let peak = max(headFraction, 0.0002)
        return LinearGradient(
            stops: [
                .init(color: sunlight.opacity(0), location: 0),
                .init(color: sunlight.opacity(midAlpha), location: mid),
                .init(color: sunlight.opacity(peakAlpha), location: peak),
                .init(color: sunlight.opacity(peakAlpha), location: 1),
            ],
            startPoint: .leading, endPoint: .trailing)
    }
}
