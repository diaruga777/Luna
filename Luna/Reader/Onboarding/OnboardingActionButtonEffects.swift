//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import UIKit

enum OnboardingActionButtonTiming {
    static let pressDuration: TimeInterval = 0.68
    static let waveDuration: CFTimeInterval = 0.74
    /// Half-width of the two-lobed annular displacement band.
    static let wavefrontHalfWidth: CGFloat = 30
    static let maximumDisplacement: CGFloat = 26
    /// The Safari/card crossfade is confined to the distorted wavefront.
    static let revealHalfWidth: CGFloat = 14
    /// A transient motion raster; lower than the 3× display scale so Core Image
    /// can sustain a smooth wave instead of presenting only a few heavy frames.
    static let waveRasterScale: CGFloat = 1.5
}

/// A full-screen mock source that can demonstrate saving its visible URL with
/// the physical Action Button. Safari and Messages both inherit this player so
/// their press cue, URL highlight, wave timing, and destination transition can
/// never drift apart.
@MainActor
class OnboardingSaveSourceViewController: UIViewController {
    var onActionButtonWaveFinished: (() -> Void)?
    var makeActionButtonDestinationSnapshot: (() -> UIImage?)?

    private var actionCue: ActionButtonPressCue?
    private var waveAnimator: LiquidScreenWaveAnimator?

    /// The currently visible URL. Sources may override this when their mock
    /// content changes while the onboarding loop is running.
    var sharedURLString: String { "" }

    /// Removes transient pressed-state decoration before this source grows back
    /// out of the saved card.
    func prepareForPresentation() {
        setURLHighlighted(false)
    }

    /// Subclasses apply the bright app-tint wash to their visible URL.
    func setURLHighlighted(_ highlighted: Bool) {}

    var isURLHighlighted: Bool { false }

    /// Plays the same complete save gesture for every mock source. The URL is
    /// highlighted before the source snapshot is captured, so it remains lit
    /// until the advancing wave replaces it with the saved-card view.
    final func replayActionButtonSaveEffect() {
        guard actionCue == nil, waveAnimator == nil,
              let window = view.window
        else { return }

        setURLHighlighted(true)
        view.layoutIfNeeded()

        let cue = ActionButtonPressCue()
        actionCue = cue
        cue.layout(in: window)
        let origin = cue.waveOrigin

        let animator = LiquidScreenWaveAnimator(
            window: window,
            hostView: view.superview ?? window)
        waveAnimator = animator
        animator.play(
            origin: origin,
            destinationSnapshot: { [weak self] in
                self?.makeActionButtonDestinationSnapshot?()
            },
            completion: { [weak self, weak cue] in
                cue?.removeFromSuperview()
                self?.actionCue = nil
                self?.waveAnimator = nil
                self?.onActionButtonWaveFinished?()
            })

        window.addSubview(cue)
        cue.play { [weak self, weak cue] in
            cue?.removeFromSuperview()
            self?.actionCue = nil
        }
    }
}

/// The solid-black edge deformation iOS shows when the physical Action Button
/// is pressed. It grows out of the display edge as one continuous silhouette,
/// then smoothly retracts back into it.
final class ActionButtonPressCue: UIView {
    private let silhouette = CAShapeLayer()

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.anchorPoint = CGPoint(x: 0, y: 0.5)
        transform = CGAffineTransform(scaleX: 0.01, y: 0.76)

        silhouette.fillColor = UIColor.black.cgColor
        layer.addSublayer(silhouette)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        silhouette.frame = bounds

        let width = bounds.width
        let height = bounds.height
        let path = UIBezierPath()
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: 1, y: 0))
        path.addCurve(
            to: CGPoint(x: width * 0.76, y: height * 0.28),
            controlPoint1: CGPoint(x: width * 0.05, y: height * 0.11),
            controlPoint2: CGPoint(x: width * 0.62, y: height * 0.17))
        path.addCurve(
            to: CGPoint(x: width, y: height * 0.50),
            controlPoint1: CGPoint(x: width * 0.92, y: height * 0.36),
            controlPoint2: CGPoint(x: width, y: height * 0.42))
        path.addCurve(
            to: CGPoint(x: width * 0.76, y: height * 0.72),
            controlPoint1: CGPoint(x: width, y: height * 0.58),
            controlPoint2: CGPoint(x: width * 0.92, y: height * 0.64))
        path.addCurve(
            to: CGPoint(x: 1, y: height),
            controlPoint1: CGPoint(x: width * 0.62, y: height * 0.83),
            controlPoint2: CGPoint(x: width * 0.05, y: height * 0.89))
        path.addLine(to: CGPoint(x: 0, y: height))
        path.close()
        silhouette.path = path.cgPath
    }

    func layout(in window: UIWindow) {
        let size = CGSize(width: 30, height: 164)
        bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(
            x: 0,
            y: window.safeAreaInsets.top + 58 + size.height / 2)
        setNeedsLayout()
        layoutIfNeeded()
    }

    var waveOrigin: CGPoint {
        CGPoint(x: 0, y: frame.midY)
    }

    func play(completion: @escaping () -> Void) {
        alpha = 1
        transform = CGAffineTransform(scaleX: 0.01, y: 0.76)
        UIView.animateKeyframes(
            withDuration: UIAccessibility.isReduceMotionEnabled
                ? 0.20
                : OnboardingActionButtonTiming.pressDuration,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.38) {
                self.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.38, relativeDuration: 0.20) {
                self.transform = CGAffineTransform(scaleX: 0.94, y: 0.98)
            }
            UIView.addKeyframe(withRelativeStartTime: 0.58, relativeDuration: 0.42) {
                self.transform = CGAffineTransform(scaleX: 0.01, y: 0.76)
            }
        } completion: { _ in
            completion()
        }
    }
}

/// An annular Core Image displacement wave over onboarding-surface before/after
/// snapshots. The advancing wavefront reveals the saved-card screen as it
/// distorts the pixels, so the content transformation and wave are one effect.
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

    private static let revealKernel = CIColorKernel(source: """
        kernel vec4 lunaWaveReveal(
            __sample source, __sample destination,
            vec2 center, float radius, float halfWidth
        ) {
            float distanceFromCenter = length(destCoord() - center);
            float reveal = 1.0 - smoothstep(
                radius - halfWidth, radius + halfWidth, distanceFromCenter);
            return mix(source, destination, reveal);
        }
        """)

    private weak var window: UIWindow?
    private weak var hostView: UIView?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var overlay: UIImageView?
    private var source: CIImage?
    private var destination: CIImage?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var origin: CGPoint = .zero
    private let duration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.waveDuration)

    init(window: UIWindow, hostView: UIView) {
        self.window = window
        self.hostView = hostView
    }

    func play(
        origin: CGPoint,
        destinationSnapshot: @escaping () -> UIImage?,
        completion: @escaping () -> Void
    ) {
        let capturedSource = hostView.flatMap { snapshot(view: $0) }
        let capturedDestination = destinationSnapshot()
        guard let window,
              let hostView,
              let sourceSnapshot = capturedSource,
              let sourceImage = sourceSnapshot.cgImage,
              let destinationImage = capturedDestination?.cgImage
        else {
            completion()
            return
        }
        self.origin = hostView.convert(origin, from: window)
        self.completion = completion
        source = CIImage(cgImage: sourceImage)
        destination = CIImage(cgImage: destinationImage)

        let imageView = UIImageView(frame: hostView.bounds)
        imageView.image = sourceSnapshot
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        hostView.addSubview(imageView)
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

    private func snapshot(view: UIView) -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = OnboardingActionButtonTiming.waveRasterScale
        format.opaque = true
        return UIGraphicsImageRenderer(bounds: view.bounds, format: format).image { _ in
            view.drawHierarchy(in: view.bounds, afterScreenUpdates: true)
        }
    }

    @objc private func tick(_ link: CADisplayLink) {
        guard let source, let destination, let overlay, let window else {
            finish()
            return
        }
        let progress = min(max((link.timestamp - startedAt) / duration, 0), 1)
        let extent = source.extent
        let pixelScale = extent.width / max(hostView?.bounds.width ?? window.bounds.width, 1)
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

        guard let waveKernel = Self.waveKernel,
            let revealKernel = Self.revealKernel,
            let revealedFrame = revealKernel.apply(
                extent: extent,
                arguments: [
                    source,
                    destination,
                    CIVector(x: center.x, y: center.y),
                    NSNumber(value: Double(radius)),
                    NSNumber(value: Double(
                        OnboardingActionButtonTiming.revealHalfWidth * pixelScale)),
                ])?.cropped(to: extent),
            let output = waveKernel.apply(
                extent: extent,
                roiCallback: { _, rect in
                    rect.insetBy(dx: -roiPadding, dy: -roiPadding)
                },
                image: revealedFrame.clampedToExtent(),
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
        let overlayToRemove = overlay
        overlay = nil
        source = nil
        destination = nil
        let completion = completion
        self.completion = nil
        completion?()
        overlayToRemove?.removeFromSuperview()
    }
}
