//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import UIKit

enum OnboardingActionButtonTiming {
    static let pressDuration: TimeInterval = 0.68
    static let waveDuration: CFTimeInterval = 0.74
    /// Half-width of the annular displacement band. The old bump filter bent
    /// everything inside the growing radius, which read as one very long wave.
    static let wavefrontHalfWidth: CGFloat = 18
    static let maximumDisplacement: CGFloat = 17
}

/// The illuminated, inset side rail iOS shows when the physical Action Button
/// is pressed. A dim rounded track hugs the leading display edge while a warm
/// white core blooms inside it, matching the real device response more closely
/// than the old solid-black bezel deformation.
final class ActionButtonPressCue: UIView {
    private let track = CAShapeLayer()
    private let core = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.72, y: 0.48)

        track.fillColor = UIColor.black.withAlphaComponent(0.48).cgColor
        track.strokeColor = UIColor.white.withAlphaComponent(0.16).cgColor
        track.lineWidth = 0.75
        layer.addSublayer(track)

        core.fillColor = UIColor(
            red: 1.0, green: 0.94, blue: 0.48, alpha: 1).cgColor
        core.shadowColor = UIColor(
            red: 1.0, green: 0.86, blue: 0.20, alpha: 1).cgColor
        core.shadowOpacity = 0.92
        core.shadowRadius = 7
        core.shadowOffset = .zero
        layer.addSublayer(core)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        track.frame = bounds
        track.path = UIBezierPath(
            roundedRect: bounds,
            cornerRadius: bounds.width / 2).cgPath

        let coreRect = bounds.insetBy(dx: 3.5, dy: 10)
        core.frame = bounds
        core.path = UIBezierPath(
            roundedRect: coreRect,
            cornerRadius: coreRect.width / 2).cgPath
        core.shadowPath = UIBezierPath(
            roundedRect: coreRect,
            cornerRadius: coreRect.width / 2).cgPath
    }

    func layout(in window: UIWindow) {
        let size = CGSize(width: 13, height: 82)
        bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(
            x: 2,
            y: window.safeAreaInsets.top + 82 + size.height / 2)
        setNeedsLayout()
        layoutIfNeeded()
    }

    var waveOrigin: CGPoint {
        CGPoint(x: 0, y: frame.midY)
    }

    func play(completion: @escaping () -> Void) {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.72, y: 0.48)
        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.20
                : OnboardingActionButtonTiming.pressDuration,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.24) {
                self.alpha = 1
                self.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.24, relativeDuration: 0.34) {
                self.transform = CGAffineTransform(scaleX: 0.88, y: 0.82)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.42) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 0.76, y: 0.52)
            }
        } completion: { _ in
            self.alpha = 0
            completion()
        }
    }
}

/// A narrow annular Core Image displacement wave over a whole-window snapshot,
/// expanding from the physical Action Button cue at the screen's leading edge.
@MainActor
final class LiquidScreenWaveAnimator {
    private static let waveKernel = CIWarpKernel(source: """
        kernel vec2 lunaAnnularWave(
            vec2 center, float radius, float halfWidth, float amplitude
        ) {
            vec2 destination = destCoord();
            vec2 delta = destination - center;
            float distanceFromCenter = length(delta);
            float normalized = (distanceFromCenter - radius) / halfWidth;
            float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
            float compression = sin(normalized * 3.14159265359);
            vec2 direction = delta / max(distanceFromCenter, 1.0);
            return destination - direction * (band * compression * amplitude);
        }
        """)

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
        let radius = max(
            1,
            CGFloat(progress)
                * (farthestCornerDistance
                    + OnboardingActionButtonTiming.wavefrontHalfWidth * pixelScale))
        let attack = min(CGFloat(progress) / 0.12, 1)
        let release = 1 - min(max((CGFloat(progress) - 0.82) / 0.18, 0), 1)
        let temporalEnvelope = sin(attack * .pi / 2) * release
        let halfWidth = OnboardingActionButtonTiming.wavefrontHalfWidth * pixelScale
        let displacement =
            OnboardingActionButtonTiming.maximumDisplacement
            * pixelScale
            * temporalEnvelope
        let roiPadding = displacement + 2

        guard let kernel = Self.waveKernel,
            let output = kernel.apply(
                extent: extent,
                roiCallback: { _, rect in
                    rect.insetBy(dx: -roiPadding, dy: -roiPadding)
                },
                image: source.clampedToExtent(),
                arguments: [
                    CIVector(x: center.x, y: center.y),
                    NSNumber(value: Double(radius)),
                    NSNumber(value: Double(halfWidth)),
                    NSNumber(value: Double(displacement)),
                ])?.cropped(to: extent),
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
