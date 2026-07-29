//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import LunaDesignSystem
import UIKit

enum OnboardingActionButtonTiming {
    static let waveDuration: CFTimeInterval = 0.78
}

final class ActionButtonPressCue: UIVisualEffectView {
    private let rim = CAShapeLayer()
    private let glow = UIView()

    init() {
        super.init(effect: GlassStyle.barEffect())
        isUserInteractionEnabled = false
        if #available(iOS 26.0, *) {
            cornerConfiguration = .capsule()
        } else {
            layer.cornerRadius = 19
            layer.cornerCurve = .continuous
            clipsToBounds = true
        }
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.62, y: 0.62)

        glow.backgroundColor = LunaSurfacePalette.baseColor.withAlphaComponent(0.88)
        glow.layer.cornerRadius = 3
        contentView.addSubview(glow)

        rim.fillColor = UIColor.clear.cgColor
        rim.strokeColor = UIColor.white.withAlphaComponent(0.72).cgColor
        rim.lineWidth = 1
        layer.addSublayer(rim)
        layer.shadowColor = LunaSurfacePalette.baseColor.cgColor
        layer.shadowOpacity = 0
        layer.shadowRadius = 14
        layer.shadowOffset = .zero
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    func layout(in window: UIWindow) {
        frame = CGRect(
            x: -8,
            y: window.safeAreaInsets.top + 68,
            width: 38,
            height: 78)
        glow.frame = CGRect(x: 23, y: 26, width: 6, height: 26)
        rim.frame = bounds
        rim.path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1),
            cornerRadius: bounds.width / 2).cgPath
    }

    var waveOrigin: CGPoint {
        CGPoint(x: 0, y: frame.midY)
    }

    func play(completion: @escaping () -> Void) {
        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.25 : 0.82,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.26) {
                self.alpha = 1
                self.transform = .identity
                self.layer.shadowOpacity = 0.85
            }
            UIView.addKeyframe(withRelativeStartTime: 0.26, relativeDuration: 0.24) {
                self.transform = CGAffineTransform(scaleX: 0.88, y: 0.92)
                self.glow.transform = CGAffineTransform(scaleX: 1.2, y: 0.72)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.50, relativeDuration: 0.50) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 1.18, y: 1.08)
                self.glow.transform = .identity
                self.layer.shadowOpacity = 0
            }
        } completion: { _ in completion() }
    }
}

/// A circular Core Image displacement wave over a whole-window snapshot,
/// expanding from the physical Action Button cue at the screen's leading edge.
@MainActor
final class LiquidScreenWaveAnimator {
    private weak var window: UIWindow?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var overlay: UIImageView?
    private var source: CIImage?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var origin: CGPoint = .zero
    private let duration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.waveDuration)

    init(window: UIWindow) {
        self.window = window
    }

    func play(origin: CGPoint, completion: @escaping () -> Void) {
        guard let window, let snapshot = snapshot(window: window),
              let cgImage = snapshot.cgImage else {
            completion()
            return
        }
        self.origin = origin
        self.completion = completion
        source = CIImage(cgImage: cgImage)

        let imageView = UIImageView(frame: window.bounds)
        imageView.image = snapshot
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        window.addSubview(imageView)
        overlay = imageView

        startedAt = CACurrentMediaTime()
        let link = CADisplayLink(target: self, selector: #selector(tick(_:)))
        if #available(iOS 15.0, *) {
            link.preferredFrameRateRange = CAFrameRateRange(
                minimum: 30, maximum: 60, preferred: 60)
        }
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func snapshot(window: UIWindow) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = window.screen.scale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let source, let overlay, let window else {
            finish()
            return
        }
        let progress = min(max((link.timestamp - startedAt) / duration, 0), 1)
        let pixelScale = window.screen.scale
        let extent = source.extent
        let center = CGPoint(
            x: origin.x * pixelScale,
            y: extent.height - origin.y * pixelScale)
        let farthestCornerDistance = [
            hypot(center.x - extent.minX, center.y - extent.minY),
            hypot(center.x - extent.maxX, center.y - extent.minY),
            hypot(center.x - extent.minX, center.y - extent.maxY),
            hypot(center.x - extent.maxX, center.y - extent.maxY),
        ].max() ?? extent.width
        let radius = max(1, CGFloat(progress) * (farthestCornerDistance + 24 * pixelScale))
        let envelope = sin(CGFloat(progress) * .pi)
        // Core Image's scale is a unit scalar (-1...1), not a pixel distance.
        // Radius owns the expanding circular front; scale owns its bend and
        // falls back to zero as the last pixels settle.
        let distortionScale = envelope * 0.62

        guard let filter = CIFilter(
            name: "CIBumpDistortion",
            parameters: [
                kCIInputImageKey: source.clampedToExtent(),
                kCIInputCenterKey: CIVector(x: center.x, y: center.y),
                kCIInputRadiusKey: radius,
                kCIInputScaleKey: distortionScale,
            ]),
            let output = filter.outputImage?.cropped(to: extent),
            let rendered = context.createCGImage(output, from: extent)
        else {
            finish()
            return
        }
        overlay.image = UIImage(
            cgImage: rendered, scale: pixelScale, orientation: .up)
        if progress >= 1 { finish() }
    }

    private func finish() {
        displayLink?.invalidate()
        displayLink = nil
        overlay?.removeFromSuperview()
        overlay = nil
        source = nil
        let completion = completion
        self.completion = nil
        completion?()
    }
}
