//
//  MoonHorizonProgress.swift
//  Luna
//

import SwiftUI
import UIKit

/// The shared geometry + palette for the "moon horizon" progress treatment: a
/// full-width, very slightly curved lunar horizon. The sun's first light creeps
/// along it from left to right as progress advances — a single brilliant point
/// marks the head (the sun just peeking over the horizon), a faint pre-dawn glow
/// trails it to the left, and the horizon ahead (to the right) stays dark.
/// Stylized, not hyperrealistic.
public enum MoonHorizonStyle {

    /// Warm sunlight for the illuminated stretch of horizon: pale gold against a
    /// dark sky, a deeper amber where the background is light so it still reads.
    public static let sunlight = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.90, blue: 0.72, alpha: 1)
            : UIColor(red: 0.96, green: 0.68, blue: 0.24, alpha: 1)
    }
    /// The white-hot center of the sun point itself.
    public static let sunCore = UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white
            : UIColor(red: 0.98, green: 0.58, blue: 0.12, alpha: 1)
    }

    /// The unlit horizon ahead of the sun — barely-there in either appearance.
    public static func darkHorizon(for traits: UITraitCollection) -> UIColor {
        let alpha: CGFloat = traits.userInterfaceStyle == .dark ? 0.30 : 0.18
        return UIColor.label.resolvedColor(with: traits).withAlphaComponent(alpha)
    }

    /// The faint suggestion of the moon's surface below the horizon line.
    public static func surface(for traits: UITraitCollection) -> UIColor {
        UIColor.label.resolvedColor(with: traits).withAlphaComponent(0.05)
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
}

// MARK: - UIKit

/// A drop-in replacement for a determinate `UIProgressView` drawn as the moon
/// horizon: dark limb ahead, the faint glow of pre-dawn light gathering behind,
/// and one brilliant point where the sun peeks over the horizon at the head of
/// progress. Spans whatever width it's given.
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

    public private(set) var progress: Float = 0

    public override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isAccessibilityElement = true
        accessibilityTraits = .updatesFrequently
        accessibilityLabel = "Progress"

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
        headBloomLayer.type = .radial
        headBloomLayer.bounds = CGRect(x: 0, y: 0, width: bloomDiameter, height: bloomDiameter)
        headBloomLayer.startPoint = CGPoint(x: 0.5, y: 0.5)
        headBloomLayer.endPoint = CGPoint(x: 1, y: 1)
        headBloomLayer.locations = [0, 0.12, 0.42, 1]
        layer.addSublayer(headBloomLayer)

        let coreDiameter: CGFloat = 3
        headCoreLayer.bounds = CGRect(x: 0, y: 0, width: coreDiameter, height: coreDiameter)
        headCoreLayer.cornerRadius = coreDiameter / 2
        headCoreLayer.shadowOpacity = 1
        headCoreLayer.shadowRadius = 2.5
        headCoreLayer.shadowOffset = .zero
        layer.addSublayer(headCoreLayer)

        updateAppearanceColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) {
            (self: Self, _: UITraitCollection) in
            self.updateAppearanceColors()
        }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: 20)
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
            sunCore.withAlphaComponent(0.55).cgColor,
            sunlight.withAlphaComponent(0.16).cgColor,
            sunlight.withAlphaComponent(0).cgColor,
        ]
        headCoreLayer.backgroundColor = sunCore.cgColor
        headCoreLayer.shadowColor = sunCore.cgColor
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
public struct MoonHorizonProgressView: View {
    private let progress: Double
    @Environment(\.colorScheme) private var colorScheme

    public init(progress: Double) {
        self.progress = min(1, max(0, progress))
    }

    public var body: some View {
        let sunlight = Color(MoonHorizonStyle.sunlight)
        let sunCore = Color(MoonHorizonStyle.sunCore)
        let darkHorizonOpacity = colorScheme == .dark ? 0.30 : 0.18
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
                            .init(color: sunCore.opacity(0.55), location: 0.12),
                            .init(color: sunlight.opacity(0.16), location: 0.42),
                            .init(color: sunlight.opacity(0), location: 1),
                        ],
                        center: .center, startRadius: 0, endRadius: 13))
                    .frame(width: 26, height: 26)
                    .position(head)
                Circle()
                    .fill(sunCore)
                    .frame(width: 3, height: 3)
                    .shadow(color: sunCore, radius: 1.5)
                    .position(head)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int(progress * 100))%")
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
