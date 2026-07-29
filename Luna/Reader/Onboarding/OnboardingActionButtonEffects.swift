//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import UIKit

enum OnboardingActionButtonTiming {
    static let pressDuration: TimeInterval = 0.56
    static let waveDuration: CFTimeInterval = 0.74
    /// Half-width of the annular displacement band. The old bump filter bent
    /// everything inside the growing radius, which read as one very long wave.
    static let wavefrontHalfWidth: CGFloat = 14
    static let maximumDisplacement: CGFloat = 11
}

/// A small piece of the black device bezel that pushes smoothly into the
/// leading screen edge. It deliberately has no glass, highlight, or rim: the
/// system Action Button response reads as the physical bezel deforming, not as
/// a control floating over the page.
final class ActionButtonPressCue: UIView {
    private let bezel = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.04, y: 0.82)
        bezel.fillColor = UIColor.black.cgColor
        layer.addSublayer(bezel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        bezel.frame = bounds
        let width = bounds.width
        let height = bounds.height
        let middle = height / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addCurve(
            to: CGPoint(x: width * 0.86, y: height * 0.30),
            controlPoint1: CGPoint(x: width * 0.63, y: 0),
            controlPoint2: CGPoint(x: width * 0.86, y: height * 0.13))
        path.addCurve(
            to: CGPoint(x: width, y: middle),
            controlPoint1: CGPoint(x: width * 0.86, y: height * 0.40),
            controlPoint2: CGPoint(x: width, y: height * 0.43))
        path.addCurve(
            to: CGPoint(x: width * 0.86, y: height * 0.70),
            controlPoint1: CGPoint(x: width, y: height * 0.57),
            controlPoint2: CGPoint(x: width * 0.86, y: height * 0.60))
        path.addCurve(
            to: CGPoint(x: 0, y: height),
            controlPoint1: CGPoint(x: width * 0.86, y: height * 0.87),
            controlPoint2: CGPoint(x: width * 0.63, y: height))
        path.close()
        bezel.path = path.cgPath
    }

    func layout(in window: UIWindow) {
        let size = CGSize(width: 24, height: 60)
        bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(
            x: 0,
            y: window.safeAreaInsets.top + 74 + size.height / 2)
        setNeedsLayout()
        layoutIfNeeded()
    }

    var waveOrigin: CGPoint {
        CGPoint(x: 0, y: frame.midY)
    }

    func play(completion: @escaping () -> Void) {
        alpha = 0
        transform = CGAffineTransform(scaleX: 0.04, y: 0.82)
        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.20
                : OnboardingActionButtonTiming.pressDuration,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.30) {
                self.alpha = 1
                self.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.30, relativeDuration: 0.22) {
                self.transform = CGAffineTransform(scaleX: 0.78, y: 0.91)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.52, relativeDuration: 0.48) {
                self.alpha = 0
                self.transform = CGAffineTransform(scaleX: 0.04, y: 0.78)
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
