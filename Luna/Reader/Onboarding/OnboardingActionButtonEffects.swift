//
//  OnboardingActionButtonEffects.swift
//  Luna
//

import CoreImage
import UIKit

enum OnboardingActionButtonTiming {
    static let pressDuration: TimeInterval = 0.68
    /// The screen holds still for a beat while the press bump forms; the first
    /// wave sets out only once the bulge is fully grown.
    static let firstWaveDelay: CFTimeInterval = 0.2
    static let firstWaveDuration: CFTimeInterval = 0.82
    static let blackoutWaveDuration: CFTimeInterval = 0.72
    /// The isolated link rests on black before the crossfade begins.
    static let saveCrossfadeDelay: CFTimeInterval = 0.5
    static let saveCrossfadeDuration: CFTimeInterval = 0.52
    /// Matches the small bezel intrusion of the system button-press response.
    static let pressCueSize = CGSize(width: 7, height: 120)
    /// Centers the cue on the iPhone 17 Pro Action Button's physical position.
    static let actionButtonCenterBelowSafeArea: CGFloat = 129
    /// The displacement-only wave has the longer wavelength.
    static let firstWavefrontHalfWidth: CGFloat = 46
    static let firstMaximumDisplacement: CGFloat = 30
    static let firstWaveLightingStrength: CGFloat = 0.20
    /// The second wave sweeps in from the display edges, blackening every
    /// pixel behind its inward-travelling front until only the highlighted
    /// link is left visible on black.
    static let blackoutWavefrontHalfWidth: CGFloat = 30
    static let blackoutMaximumDisplacement: CGFloat = 24
    static let blackoutRevealHalfWidth: CGFloat = 12
    /// A transient motion raster; lower than the 3× display scale so Core Image
    /// can sustain a smooth wave instead of presenting only a few heavy frames.
    static let waveRasterScale: CGFloat = 1.5
}

struct OnboardingHighlightedLinkRegion: Equatable {
    /// Frame in the source view controller's root-view coordinate space.
    var frame: CGRect
    var cornerRadius: CGFloat
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

    /// The highlighted URL UI that remains visible while the second wave turns
    /// every pixel beyond its rounded boundary black.
    var highlightedLinkRegion: OnboardingHighlightedLinkRegion? { nil }

    /// Plays the same complete save gesture for every mock source. The URL is
    /// highlighted before the source snapshot is captured, so it remains lit
    /// until the advancing wave replaces it with the saved-card view.
    final func replayActionButtonSaveEffect() {
        guard actionCue == nil, waveAnimator == nil,
              let window = view.window
        else { return }

        setURLHighlighted(true)
        view.layoutIfNeeded()
        guard let sourceLinkRegion = highlightedLinkRegion else {
            setURLHighlighted(false)
            return
        }

        let cue = ActionButtonPressCue()
        actionCue = cue
        cue.layout(in: window)
        let origin = cue.waveOrigin

        let hostView = view.superview ?? window
        let linkRegion = OnboardingHighlightedLinkRegion(
            frame: hostView.convert(sourceLinkRegion.frame, from: view),
            cornerRadius: sourceLinkRegion.cornerRadius)
        let animator = LiquidScreenWaveAnimator(window: window, hostView: hostView)
        waveAnimator = animator

        window.addSubview(cue)
        animator.play(
            origin: origin,
            highlightedLinkRegion: linkRegion,
            destinationSnapshot: { [weak self] in
                self?.makeActionButtonDestinationSnapshot?()
            },
            completion: { [weak self, weak cue] in
                cue?.removeFromSuperview()
                self?.actionCue = nil
                self?.waveAnimator = nil
                self?.onActionButtonWaveFinished?()
            })
        cue.play { [weak self, weak cue] in
            cue?.removeFromSuperview()
            self?.actionCue = nil
        }
    }

    /// Stops an in-flight replay without reporting a completed save.
    ///
    /// Instruction buttons remain interactive while the demonstration loops
    /// behind them. An external hop or "Set up later" can therefore arrive in
    /// any of the three wave phases; cancelling here prevents that stale wave
    /// from committing a card transition after the flow has already moved on.
    final func cancelActionButtonSaveEffect() {
        actionCue?.layer.removeAllAnimations()
        actionCue?.removeFromSuperview()
        actionCue = nil
        waveAnimator?.cancel()
        waveAnimator = nil
        setURLHighlighted(false)
    }

    #if DEBUG
    var hasActiveActionButtonSaveEffectForTesting: Bool {
        actionCue != nil || waveAnimator != nil
    }
    #endif
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

/// A three-beat Core Image transition: an in-place Action Button ripple, a
/// rounded wave that closes in from the display edges to isolate the
/// highlighted link against black, then a plain crossfade into the saved-card
/// screen.
@MainActor
final class LiquidScreenWaveAnimator {
    private static let radialWaveKernel = CIWarpKernel(source: """
        kernel vec2 lunaRadialWave(
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

    private static let roundedRectWaveKernel = CIWarpKernel(source: """
        kernel vec2 lunaRoundedRectWave(
            vec2 center, vec2 halfSize, float cornerRadius,
            float radius, float halfWidth, float amplitude
        ) {
            vec2 destination = destCoord();
            vec2 local = destination - center;
            vec2 innerHalfSize = max(
                halfSize - vec2(cornerRadius), vec2(0.0));
            vec2 nearestDelta =
                local - clamp(local, -innerHalfSize, innerHalfSize);
            float nearestLength = length(nearestDelta);
            float signedDistance = nearestLength - cornerRadius;
            float normalized = (signedDistance - radius) / halfWidth;
            float band = 1.0 - smoothstep(0.0, 1.0, abs(normalized));
            float compression = sin(normalized * 3.14159265359);
            float outside = smoothstep(-1.0, 1.0, signedDistance);
            vec2 direction = nearestDelta / max(nearestLength, 1.0);
            return destination
                - direction * (band * compression * amplitude * outside);
        }
        """)

    private static let blackoutKernel = CIColorKernel(source: """
        kernel vec4 lunaBlackOutsideHighlightedLink(
            __sample displaced, __sample original,
            vec2 center, vec2 halfSize, float cornerRadius,
            float radius, float halfWidth
        ) {
            vec2 local = destCoord() - center;
            vec2 innerHalfSize = max(
                halfSize - vec2(cornerRadius), vec2(0.0));
            vec2 nearestDelta =
                local - clamp(local, -innerHalfSize, innerHalfSize);
            float signedDistance = length(nearestDelta) - cornerRadius;
            float outside = smoothstep(-1.0, 1.0, signedDistance);
            float outsideDistance = max(signedDistance, 0.0);
            float coverage = smoothstep(
                radius - halfWidth, radius + halfWidth, outsideDistance);
            vec4 blackened = mix(
                displaced, vec4(0.0, 0.0, 0.0, 1.0), coverage);
            return mix(original, blackened, outside);
        }
        """)

    private static let crossfadeKernel = CIColorKernel(source: """
        kernel vec4 lunaSaveCrossfade(
            __sample source, __sample destination, float progress
        ) {
            return mix(source, destination, progress);
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

    /// CIContext creation is intentionally expensive because it owns device
    /// rendering resources and shader caches. The onboarding loop replays this
    /// effect many times, so one process-wide context avoids a setup hitch and
    /// cache churn at the start of every save wave.
    private static let context = CIContext(options: [.cacheIntermediates: false])

    private weak var window: UIWindow?
    private weak var hostView: UIView?
    private var overlay: UIImageView?
    private var source: CIImage?
    private var destination: CIImage?
    private var displayLink: CADisplayLink?
    private var startedAt: CFTimeInterval = 0
    private var completion: (() -> Void)?
    private var origin: CGPoint = .zero
    private var highlightedLinkRegion = OnboardingHighlightedLinkRegion(
        frame: .zero,
        cornerRadius: 0)
    private let firstWaveDelay = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.firstWaveDelay)
    private let firstWaveDuration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.firstWaveDuration)
    private let blackoutWaveDuration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.blackoutWaveDuration)
    private let saveCrossfadeDelay = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.saveCrossfadeDelay)
    private let saveCrossfadeDuration = OnboardingAnimationClock.displayLinkDuration(
        OnboardingActionButtonTiming.saveCrossfadeDuration)

    init(window: UIWindow, hostView: UIView) {
        self.window = window
        self.hostView = hostView
    }

    func play(
        origin: CGPoint,
        highlightedLinkRegion: OnboardingHighlightedLinkRegion,
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
        self.highlightedLinkRegion = highlightedLinkRegion
        self.completion = completion
        source = CIImage(cgImage: sourceImage)
        destination = CIImage(cgImage: destinationImage)

        let imageView = UIImageView(frame: hostView.bounds)
        imageView.image = sourceSnapshot
        imageView.contentMode = .scaleToFill
        imageView.isUserInteractionEnabled = false
        hostView.addSubview(imageView)
        overlay = imageView

        if UIAccessibility.isReduceMotionEnabled {
            UIView.transition(
                with: imageView,
                duration: 0.20,
                options: [.transitionCrossDissolve, .beginFromCurrentState]
            ) {
                imageView.image = capturedDestination
            } completion: { [weak self] _ in
                self?.finish()
            }
            return
        }

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
        // The overlay is already showing the untouched source snapshot, so the
        // press-bump beat before the first wave needs no rendering at all.
        if elapsed < firstWaveDelay { return }
        let extent = source.extent
        let pixelScale = extent.width
            / max(hostView?.bounds.width ?? window.bounds.width, 1)
        let actionButtonCenter = CGPoint(
            x: origin.x * pixelScale,
            y: extent.height - origin.y * pixelScale)
        let linkFrame = CGRect(
            x: highlightedLinkRegion.frame.minX * pixelScale,
            y: extent.height - highlightedLinkRegion.frame.maxY * pixelScale,
            width: highlightedLinkRegion.frame.width * pixelScale,
            height: highlightedLinkRegion.frame.height * pixelScale)
        let linkCenter = CGPoint(x: linkFrame.midX, y: linkFrame.midY)
        let linkHalfSize = CGSize(
            width: linkFrame.width / 2,
            height: linkFrame.height / 2)
        let linkCornerRadius = min(
            highlightedLinkRegion.cornerRadius * pixelScale,
            min(linkHalfSize.width, linkHalfSize.height))

        let firstHalfWidth =
            OnboardingActionButtonTiming.firstWavefrontHalfWidth * pixelScale
        let blackoutHalfWidth =
            OnboardingActionButtonTiming.blackoutWavefrontHalfWidth * pixelScale
        let blackoutRevealHalfWidth =
            OnboardingActionButtonTiming.blackoutRevealHalfWidth * pixelScale

        let firstTravelDistance = radialTravelDistance(
            from: actionButtonCenter,
            through: extent,
            padding: firstHalfWidth)
        let blackoutTravelDistance = roundedRectTravelDistance(
            from: linkCenter,
            halfSize: linkHalfSize,
            cornerRadius: linkCornerRadius,
            through: extent,
            padding: max(blackoutHalfWidth, blackoutRevealHalfWidth))

        let blackoutStartedAt = firstWaveDelay + firstWaveDuration
        // The blackout phase window extends through the on-black hold: its
        // clamped progress parks the front at the link boundary until the
        // crossfade takes over.
        let crossfadeStartedAt =
            blackoutStartedAt + blackoutWaveDuration + saveCrossfadeDelay
        let output: CIImage?
        let isComplete: Bool

        if elapsed < blackoutStartedAt {
            let progress = clampedProgress(
                (elapsed - firstWaveDelay) / firstWaveDuration)
            let envelope = temporalEnvelope(for: progress)
            output = renderFirstWave(
                source: source,
                extent: extent,
                center: actionButtonCenter,
                radius: max(1, CGFloat(progress) * firstTravelDistance),
                halfWidth: firstHalfWidth,
                displacement:
                    OnboardingActionButtonTiming.firstMaximumDisplacement
                        * pixelScale
                        * envelope,
                lightingStrength:
                    OnboardingActionButtonTiming.firstWaveLightingStrength
                        * envelope)
            isComplete = false
        } else if elapsed < crossfadeStartedAt {
            let progress = clampedProgress(
                (elapsed - blackoutStartedAt) / blackoutWaveDuration)
            let envelope = temporalEnvelope(for: progress)
            // The front starts just past the display corners and finishes at
            // -revealHalfWidth so the feathered edge fully clears the link
            // boundary, leaving everything outside it solid black.
            output = renderBlackoutWave(
                source: source,
                extent: extent,
                center: linkCenter,
                halfSize: linkHalfSize,
                cornerRadius: linkCornerRadius,
                radius: blackoutTravelDistance
                    - CGFloat(progress)
                        * (blackoutTravelDistance + blackoutRevealHalfWidth),
                waveHalfWidth: blackoutHalfWidth,
                revealHalfWidth: blackoutRevealHalfWidth,
                displacement:
                    OnboardingActionButtonTiming.blackoutMaximumDisplacement
                        * pixelScale
                        * envelope)
            isComplete = false
        } else {
            let progress = clampedProgress(
                (elapsed - crossfadeStartedAt) / saveCrossfadeDuration)
            output = renderSaveCrossfade(
                source: source,
                destination: destination,
                extent: extent,
                linkCenter: linkCenter,
                linkHalfSize: linkHalfSize,
                linkCornerRadius: linkCornerRadius,
                blackoutHalfWidth: blackoutRevealHalfWidth,
                progress: CGFloat(progress))
            isComplete = progress >= 1
        }

        guard let output,
              let rendered = Self.context.createCGImage(output, from: extent)
        else {
            finish()
            return
        }
        overlay.image = UIImage(
            cgImage: rendered, scale: pixelScale, orientation: .up)
        if isComplete { finish() }
    }

    private func renderFirstWave(
        source: CIImage,
        extent: CGRect,
        center: CGPoint,
        radius: CGFloat,
        halfWidth: CGFloat,
        displacement: CGFloat,
        lightingStrength: CGFloat
    ) -> CIImage? {
        guard let displaced = radialDisplacement(
            image: source,
            extent: extent,
            center: center,
            radius: radius,
            halfWidth: halfWidth,
            displacement: displacement),
            let lightingKernel = Self.lightingKernel
        else { return nil }
        return lightingKernel.apply(
            extent: extent,
            arguments: [
                displaced,
                CIVector(x: center.x, y: center.y),
                NSNumber(value: Double(radius)),
                NSNumber(value: Double(halfWidth)),
                NSNumber(value: Double(lightingStrength)),
            ])?.cropped(to: extent)
    }

    private func renderBlackoutWave(
        source: CIImage,
        extent: CGRect,
        center: CGPoint,
        halfSize: CGSize,
        cornerRadius: CGFloat,
        radius: CGFloat,
        waveHalfWidth: CGFloat,
        revealHalfWidth: CGFloat,
        displacement: CGFloat
    ) -> CIImage? {
        guard let roundedRectWaveKernel = Self.roundedRectWaveKernel,
              let blackoutKernel = Self.blackoutKernel,
              let displaced = roundedRectWaveKernel.apply(
                extent: extent,
                roiCallback: { _, rect in
                    rect.insetBy(
                        dx: -(abs(displacement) + 2),
                        dy: -(abs(displacement) + 2))
                },
                image: source.clampedToExtent(),
                arguments: [
                    CIVector(x: center.x, y: center.y),
                    CIVector(x: halfSize.width, y: halfSize.height),
                    NSNumber(value: Double(cornerRadius)),
                    NSNumber(value: Double(radius)),
                    NSNumber(value: Double(waveHalfWidth)),
                    NSNumber(value: Double(displacement)),
                ])?.cropped(to: extent)
        else { return nil }
        return blackoutKernel.apply(
            extent: extent,
            arguments: [
                displaced,
                source,
                CIVector(x: center.x, y: center.y),
                CIVector(x: halfSize.width, y: halfSize.height),
                NSNumber(value: Double(cornerRadius)),
                NSNumber(value: Double(radius)),
                NSNumber(value: Double(revealHalfWidth)),
            ])?.cropped(to: extent)
    }

    /// The final beat: the isolated highlighted link and its black
    /// surroundings dissolve uniformly into the saved-card screen. The
    /// blackened frame is rebuilt at the blackout wave's exact end state
    /// (radius parked at -halfWidth) so the crossfade picks up seamlessly.
    private func renderSaveCrossfade(
        source: CIImage,
        destination: CIImage,
        extent: CGRect,
        linkCenter: CGPoint,
        linkHalfSize: CGSize,
        linkCornerRadius: CGFloat,
        blackoutHalfWidth: CGFloat,
        progress: CGFloat
    ) -> CIImage? {
        guard let blackoutKernel = Self.blackoutKernel,
              let crossfadeKernel = Self.crossfadeKernel,
              let blackenedSource = blackoutKernel.apply(
                extent: extent,
                arguments: [
                    source,
                    source,
                    CIVector(x: linkCenter.x, y: linkCenter.y),
                    CIVector(
                        x: linkHalfSize.width,
                        y: linkHalfSize.height),
                    NSNumber(value: Double(linkCornerRadius)),
                    NSNumber(value: Double(-blackoutHalfWidth)),
                    NSNumber(value: Double(blackoutHalfWidth)),
                ])?.cropped(to: extent)
        else { return nil }
        let eased = progress * progress * (3 - 2 * progress)
        return crossfadeKernel.apply(
            extent: extent,
            arguments: [
                blackenedSource,
                destination,
                NSNumber(value: Double(eased)),
            ])?.cropped(to: extent)
    }

    private func radialDisplacement(
        image: CIImage,
        extent: CGRect,
        center: CGPoint,
        radius: CGFloat,
        halfWidth: CGFloat,
        displacement: CGFloat
    ) -> CIImage? {
        Self.radialWaveKernel?.apply(
            extent: extent,
            roiCallback: { _, rect in
                rect.insetBy(
                    dx: -(abs(displacement) + 2),
                    dy: -(abs(displacement) + 2))
            },
            image: image.clampedToExtent(),
            arguments: [
                CIVector(x: center.x, y: center.y),
                NSNumber(value: Double(radius)),
                NSNumber(value: Double(halfWidth)),
                NSNumber(value: Double(displacement)),
            ])?.cropped(to: extent)
    }

    private func radialTravelDistance(
        from center: CGPoint,
        through extent: CGRect,
        padding: CGFloat
    ) -> CGFloat {
        let farthestCorner = [
            hypot(center.x - extent.minX, center.y - extent.minY),
            hypot(center.x - extent.maxX, center.y - extent.minY),
            hypot(center.x - extent.minX, center.y - extent.maxY),
            hypot(center.x - extent.maxX, center.y - extent.maxY),
        ].max() ?? extent.width
        return farthestCorner + padding
    }

    private func roundedRectTravelDistance(
        from center: CGPoint,
        halfSize: CGSize,
        cornerRadius: CGFloat,
        through extent: CGRect,
        padding: CGFloat
    ) -> CGFloat {
        let innerHalfSize = CGSize(
            width: max(halfSize.width - cornerRadius, 0),
            height: max(halfSize.height - cornerRadius, 0))
        let corners = [
            CGPoint(x: extent.minX, y: extent.minY),
            CGPoint(x: extent.maxX, y: extent.minY),
            CGPoint(x: extent.minX, y: extent.maxY),
            CGPoint(x: extent.maxX, y: extent.maxY),
        ]
        let farthestCorner = corners.map { point in
            let dx = max(abs(point.x - center.x) - innerHalfSize.width, 0)
            let dy = max(abs(point.y - center.y) - innerHalfSize.height, 0)
            return max(hypot(dx, dy) - cornerRadius, 0)
        }.max() ?? extent.width
        return farthestCorner + padding
    }

    private func clampedProgress(_ progress: CFTimeInterval) -> CFTimeInterval {
        min(max(progress, 0), 1)
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

    func cancel() {
        displayLink?.invalidate()
        displayLink = nil
        overlay?.layer.removeAllAnimations()
        overlay?.removeFromSuperview()
        overlay = nil
        source = nil
        destination = nil
        completion = nil
    }
}
