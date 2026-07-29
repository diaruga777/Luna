//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import UIKit

enum OnboardingActionButtonTiming {
    static let pressDuration: TimeInterval = 0.68
    /// The first wave begins exactly as the fully formed edge bulge starts
    /// retracting, leaving a distinct press beat before any screen distortion.
    static let pressRecessionStartFraction: Double = 0.42
    static let firstWaveDuration: CFTimeInterval = 0.82
    static let waveDuration: CFTimeInterval = 0.74
    /// Matches the small bezel intrusion of the system button-press response.
    static let pressCueSize = CGSize(width: 7, height: 120)
    /// Centers the cue on the iPhone 17 Pro Action Button's physical position.
    static let actionButtonCenterBelowSafeArea: CGFloat = 129
    /// The displacement-only wave has the longer wavelength.
    static let firstWavefrontHalfWidth: CGFloat = 46
    static let firstMaximumDisplacement: CGFloat = 30
    static let firstWaveLightingStrength: CGFloat = 0.20
    /// The trailing wave retains the previous visual and reveals the save card.
    static let wavefrontHalfWidth: CGFloat = 30
    static let maximumDisplacement: CGFloat = 26
    /// The Safari/card crossfade is confined to the distorted wavefront.
    static let revealHalfWidth: CGFloat = 14
    /// A transient motion raster; lower than the 3× display scale so Core Image
    /// can sustain a smooth wave instead of presenting only a few heavy frames.
    static let waveRasterScale: CGFloat = 1.5

    static func secondWaveStartProgress(
        screenWidth: CGFloat,
        firstTravelDistance: CGFloat
    ) -> CGFloat {
        min(
            max((screenWidth * 0.5) / max(firstTravelDistance, 1), 0),
            1)
    }
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

        let hostView = view.superview ?? window
        let animator = LiquidScreenWaveAnimator(window: window, hostView: hostView)
        waveAnimator = animator

        window.addSubview(cue)
        cue.play { [weak self, weak cue] in
            cue?.removeFromSuperview()
            self?.actionCue = nil
        }

        let resolvedPressDuration = UIAccessibility.isReduceMotionEnabled
            ? 0.20
            : OnboardingActionButtonTiming.pressDuration
        let waveDelay = resolvedPressDuration
            * OnboardingActionButtonTiming.pressRecessionStartFraction
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(waveDelay)
        ) { [weak self, weak cue, weak animator] in
            guard let self,
                  let animator,
                  self.waveAnimator === animator,
                  self.actionCue === cue
            else { return }
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
        path.addCurve(
            to: CGPoint(x: width * 0.88, y: height * 0.28),
            controlPoint1: CGPoint(x: 0, y: height * 0.15),
            controlPoint2: CGPoint(x: width * 0.68, y: height * 0.17))
        path.addCurve(
            to: CGPoint(x: width, y: height * 0.40),
            controlPoint1: CGPoint(x: width * 0.97, y: height * 0.33),
            controlPoint2: CGPoint(x: width, y: height * 0.36))
        path.addLine(to: CGPoint(x: width, y: height * 0.60))
        path.addCurve(
            to: CGPoint(x: width * 0.88, y: height * 0.72),
            controlPoint1: CGPoint(x: width, y: height * 0.64),
            controlPoint2: CGPoint(x: width * 0.97, y: height * 0.67))
        path.addCurve(
            to: CGPoint(x: 0, y: height),
            controlPoint1: CGPoint(x: width * 0.68, y: height * 0.83),
            controlPoint2: CGPoint(x: 0, y: height * 0.85))
        path.close()
        silhouette.path = path.cgPath
    }

    func layout(in window: UIWindow) {
        let size = OnboardingActionButtonTiming.pressCueSize
        bounds = CGRect(origin: .zero, size: size)
        layer.position = CGPoint(
            x: 0,
            y: window.safeAreaInsets.top
                + OnboardingActionButtonTiming.actionButtonCenterBelowSafeArea)
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
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.32) {
                self.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.32, relativeDuration: 0.10) {
                self.transform = .identity
            }
            UIView.addKeyframe(withRelativeStartTime: 0.42, relativeDuration: 0.58) {
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
        kernel vec2 lunaOverlappingWaves(
            vec2 center,
            float firstRadius, float firstHalfWidth, float firstAmplitude,
            float secondRadius, float secondHalfWidth, float secondAmplitude
        ) {
            vec2 destination = destCoord();
            vec2 delta = destination - center;
            float distanceFromCenter = length(delta);
            float firstNormalized =
                (distanceFromCenter - firstRadius) / firstHalfWidth;
            float firstBand =
                1.0 - smoothstep(0.0, 1.0, abs(firstNormalized));
            float firstCompression =
                sin(firstNormalized * 3.14159265359);
            float secondNormalized =
                (distanceFromCenter - secondRadius) / secondHalfWidth;
            float secondBand =
                1.0 - smoothstep(0.0, 1.0, abs(secondNormalized));
            float secondCompression =
                sin(secondNormalized * 3.14159265359);
            float displacement =
                firstBand * firstCompression * firstAmplitude
                + secondBand * secondCompression * secondAmplitude;
            vec2 direction = delta / max(distanceFromCenter, 1.0);
            return destination - direction * displacement;
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

    private static let lightingKernel = CIColorKernel(source: """
        kernel vec4 lunaFirstWaveLighting(
            __sample image, vec2 center,
            float radius, float halfWidth, float strength
        ) {
            float distanceFromCenter = length(destCoord() - center);
            float normalized = (distanceFromCenter - radius) / halfWidth;
            float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
            float ridge = sin(normalized * 3.14159265359) * band;
            vec3 color = image.rgb;
            color += max(ridge, 0.0) * strength * (vec3(1.0) - color);
            color -= max(-ridge, 0.0) * strength * 0.72 * color;
            return vec4(color, image.a);
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
    private let firstWaveDuration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.firstWaveDuration)
    private let secondWaveDuration = OnboardingAnimationClock.displayLinkDuration(
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
        let elapsed = max(link.timestamp - startedAt, 0)
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
        let firstHalfWidth =
            OnboardingActionButtonTiming.firstWavefrontHalfWidth * pixelScale
        let secondHalfWidth =
            OnboardingActionButtonTiming.wavefrontHalfWidth * pixelScale
        let firstTravelDistance = farthestCornerDistance + firstHalfWidth
        let secondTravelDistance = farthestCornerDistance + secondHalfWidth
        let secondStartProgress =
            OnboardingActionButtonTiming.secondWaveStartProgress(
                screenWidth: extent.width,
                firstTravelDistance: firstTravelDistance)
        let secondStartedAt = firstWaveDuration
            * CFTimeInterval(secondStartProgress)

        let firstProgress = min(max(elapsed / firstWaveDuration, 0), 1)
        let secondProgress = min(
            max((elapsed - secondStartedAt) / secondWaveDuration, 0),
            1)
        let hasSecondWaveStarted = elapsed >= secondStartedAt
        let firstRadius = max(
            1,
            CGFloat(firstProgress) * firstTravelDistance)
        let secondRadius = hasSecondWaveStarted
            ? max(1, CGFloat(secondProgress) * secondTravelDistance)
            : -secondTravelDistance
        let firstEnvelope = temporalEnvelope(for: firstProgress)
        let secondEnvelope = hasSecondWaveStarted
            ? temporalEnvelope(for: secondProgress)
            : 0
        let firstDisplacement =
            OnboardingActionButtonTiming.firstMaximumDisplacement
            * pixelScale
            * firstEnvelope
        let secondDisplacement =
            OnboardingActionButtonTiming.maximumDisplacement
            * pixelScale
            * secondEnvelope
        let roiPadding =
            abs(firstDisplacement) + abs(secondDisplacement) + 2

        guard let waveKernel = Self.waveKernel,
            let revealKernel = Self.revealKernel,
            let lightingKernel = Self.lightingKernel,
            let revealedFrame = revealKernel.apply(
                extent: extent,
                arguments: [
                    source,
                    destination,
                    CIVector(x: center.x, y: center.y),
                    NSNumber(value: Double(secondRadius)),
                    NSNumber(value: Double(
                        OnboardingActionButtonTiming.revealHalfWidth * pixelScale)),
                ])?.cropped(to: extent),
            let displacedFrame = waveKernel.apply(
                extent: extent,
                roiCallback: { _, rect in
                    rect.insetBy(dx: -roiPadding, dy: -roiPadding)
                },
                image: revealedFrame.clampedToExtent(),
                arguments: [
                    CIVector(x: center.x, y: center.y),
                    NSNumber(value: Double(firstRadius)),
                    NSNumber(value: Double(firstHalfWidth)),
                    NSNumber(value: Double(firstDisplacement)),
                    NSNumber(value: Double(secondRadius)),
                    NSNumber(value: Double(secondHalfWidth)),
                    NSNumber(value: Double(secondDisplacement)),
                ])?.cropped(to: extent),
            let output = lightingKernel.apply(
                extent: extent,
                arguments: [
                    displacedFrame,
                    CIVector(x: center.x, y: center.y),
                    NSNumber(value: Double(firstRadius)),
                    NSNumber(value: Double(firstHalfWidth)),
                    NSNumber(value: Double(
                        OnboardingActionButtonTiming.firstWaveLightingStrength
                            * firstEnvelope)),
                ])?.cropped(to: extent),
            let rendered = context.createCGImage(output, from: extent)
        else {
            finish()
            return
        }
        overlay.image = UIImage(
            cgImage: rendered, scale: pixelScale, orientation: .up)
        if firstProgress >= 1, secondProgress >= 1 { finish() }
    }

    private func temporalEnvelope(for progress: CFTimeInterval) -> CGFloat {
        let progress = CGFloat(progress)
        let attack = min(progress / 0.12, 1)
        let release = 1 - min(max((progress - 0.82) / 0.18, 0), 1)
        return sin(attack * .pi / 2) * release
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
