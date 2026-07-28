//
//  AppLaunchTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum AppLaunchGeometry {
    static let referenceSize = CGSize(width: 402, height: 874)
    static let coronaReachRatio: CGFloat = 0.42
    static var totalityGroupAspectRatio: CGFloat {
        let width = 1 + coronaReachRatio * 2
        let height = 1 / CardCarouselMetrics.cardAspectRatio + coronaReachRatio * 2
        return width / height
    }

    /// The largest centered card whose entire 42%-of-body corona is on screen.
    /// Both axes participate so the launch composition stays intact in iPad
    /// landscape as well as every supported iPhone portrait size.
    static func totalityCardFrame(in bounds: CGRect) -> CGRect {
        let availableWidth = max(1, bounds.width - 10)
        let availableHeight = max(1, bounds.height - 10)
        let groupWidthFactor = 1 + coronaReachRatio * 2
        let groupHeightFactor = 1 / CardCarouselMetrics.cardAspectRatio
            + coronaReachRatio * 2
        let width = min(
            availableWidth / groupWidthFactor,
            availableHeight / groupHeightFactor)
        let height = width / CardCarouselMetrics.cardAspectRatio
        return CGRect(
            x: bounds.midX - width / 2,
            y: bounds.midY - height / 2,
            width: width,
            height: height)
    }
}

/// The live first frame of every Luna app launch. It begins at the exact
/// totality composition represented by ReaderLaunchScreen.storyboard, then
/// plays only the egress: corona down, black moon out, real card/content and
/// surrounding chrome in.
enum AppLaunchTransition {
    static let didFinish = Notification.Name("AppLaunchTransition.didFinish")
    static let duration: TimeInterval = 0.78

    static func install(in window: UIWindow) {
        window.layoutIfNeeded()
        guard window.bounds.width > 0, window.bounds.height > 0 else {
            DispatchQueue.main.async { install(in: window) }
            return
        }

        let overlay = makeTotalityView(frame: window.bounds)
        window.addSubview(overlay)
        let rootView = window.rootViewController?.view
        rootView?.alpha = 0
        rootView?.layoutIfNeeded()

        OnboardingAnimationClock.installSlowMotionIfRequested(in: window)
        let target = window.rootViewController?.appLaunchTransitionTarget()
        let targetFrame = target?.appLaunchTargetFrame(in: window)
            ?? fallbackTargetFrame(in: window)
        let body = overlay.viewWithTag(Tags.body)!
        let corona = overlay.viewWithTag(Tags.corona)!
        let sky = overlay.viewWithTag(Tags.sky)!
        let launchReplica = overlay.viewWithTag(Tags.launchReplica)

        // Preserve the launch frame for a beat. UIKit has just replaced the
        // static storyboard with this pixel-matched live hierarchy; moving it
        // synchronously would expose that handoff.
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(0.08)
        ) {
            guard overlay.window != nil else { return }
            UIView.animateKeyframes(
                withDuration: UIAccessibility.isReduceMotionEnabled ? 0.22 : duration,
                delay: 0,
                options: [.calculationModeCubic, .beginFromCurrentState]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.18) {
                    launchReplica?.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.12, relativeDuration: 0.66) {
                    body.frame = targetFrame
                    corona.frame = targetFrame
                    corona.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.36, relativeDuration: 0.64) {
                    sky.alpha = 0
                    rootView?.alpha = 1
                }
                UIView.addKeyframe(withRelativeStartTime: 0.72, relativeDuration: 0.28) {
                    body.alpha = 0
                }
            } completion: { _ in
                rootView?.alpha = 1
                overlay.removeFromSuperview()
                target?.appLaunchTransitionDidFinish()
                if target?.keepsOnboardingSlowMotionAfterLaunch != true {
                    OnboardingAnimationClock.restoreNormalSpeed(in: window)
                }
                NotificationCenter.default.post(name: didFinish, object: nil)
            }
        }
    }

    /// Also used by the launch-art recorder test. The star table, corona tint,
    /// black body, geometry, and rim are therefore one source of truth for the
    /// static launch screen and the first live UIKit frame.
    static func makeTotalityView(frame: CGRect) -> UIView {
        let overlay = UIView(frame: frame)
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = false

        let sky = AppLaunchStarfieldView(frame: overlay.bounds)
        sky.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sky.tag = Tags.sky
        overlay.addSubview(sky)

        let bodyFrame = AppLaunchGeometry.totalityCardFrame(in: overlay.bounds)
        let corona = EclipseCoronaView(
            bodySize: bodyFrame.size,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint(for: .reader))
        corona.frame = bodyFrame
        corona.tag = Tags.corona
        overlay.addSubview(corona)

        let body = CardSurfaceView(frame: bodyFrame)
        body.backgroundColor = .black
        // The exact glass rim is present in the launch-raster replica above.
        // CardSurfaceView recomputes its mask path at the destination bounds;
        // resizing it live would expose that final-width path for one frame.
        // The corona carries the edge through the move, then the destination
        // card's real glass rim crossfades in with the rest of the chrome.
        body.setBorderEnabled(false)
        let black = UIView(frame: body.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        body.installContentView(black)
        body.tag = Tags.body
        overlay.addSubview(body)
        body.layoutIfNeeded()
        corona.layoutIfNeeded()
        let launchReplica = makeLaunchScreenReplica(frame: overlay.bounds)
        launchReplica.tag = Tags.launchReplica
        overlay.addSubview(launchReplica)
        return overlay
    }

    /// Tight transparent artwork for the launch storyboard. Keeping this
    /// renderer beside the live transition prevents the launch asset from
    /// drifting away from the production corona, rim, or Reader tint.
    static func makeStaticCoronaCardView(bodyWidth: CGFloat) -> UIView {
        let bodySize = CGSize(
            width: bodyWidth,
            height: bodyWidth / CardCarouselMetrics.cardAspectRatio)
        let reach = bodyWidth * AppLaunchGeometry.coronaReachRatio
        let group = UIView(frame: CGRect(
            origin: .zero,
            size: CGSize(
                width: bodySize.width + reach * 2,
                height: bodySize.height + reach * 2)))
        group.backgroundColor = .clear
        group.isOpaque = false

        let bodyFrame = CGRect(
            x: reach, y: reach,
            width: bodySize.width, height: bodySize.height)
        let corona = EclipseCoronaView(
            bodySize: bodySize,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint(for: .reader))
        corona.frame = bodyFrame
        group.addSubview(corona)

        let body = CardSurfaceView(frame: bodyFrame)
        body.backgroundColor = .black
        body.setBorderEnabled(true)
        let black = UIView(frame: body.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        body.installContentView(black)
        group.addSubview(body)
        group.layoutIfNeeded()
        body.layoutIfNeeded()
        corona.layoutIfNeeded()
        return group
    }

    static func makeStaticStarfieldView(frame: CGRect) -> UIView {
        AppLaunchStarfieldView(frame: frame)
    }

    private static func fallbackTargetFrame(in window: UIWindow) -> CGRect {
        let width = max(40, window.bounds.width - 48)
        let height = min(
            width / CardCarouselMetrics.cardAspectRatio,
            window.bounds.height - window.safeAreaInsets.top - window.safeAreaInsets.bottom - 92)
        let resolvedWidth = height * CardCarouselMetrics.cardAspectRatio
        return CGRect(
            x: window.bounds.midX - resolvedWidth / 2,
            y: window.bounds.midY - height / 2,
            width: resolvedWidth,
            height: height)
    }

    /// The uppermost runtime layer uses the exact launch-screen assets with
    /// the storyboard's content modes and five-point inset. It guarantees that
    /// UIKit's first committed frame is pixel-identical to the cached static
    /// splash. The live production views sit registered beneath it and take
    /// over before any geometry changes.
    private static func makeLaunchScreenReplica(frame: CGRect) -> UIView {
        let replica = UIView(frame: frame)
        replica.backgroundColor = .black
        replica.isUserInteractionEnabled = false

        let stars = UIImageView(frame: replica.bounds)
        stars.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        stars.contentMode = .scaleToFill
        stars.image = UIImage(named: "ReaderLaunchStarfield")
        replica.addSubview(stars)

        let coronaCard = UIImageView(frame: replica.bounds.insetBy(dx: 5, dy: 5))
        coronaCard.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        coronaCard.contentMode = .scaleAspectFit
        coronaCard.image = UIImage(named: "ReaderLaunchCoronaCard")
        replica.addSubview(coronaCard)
        return replica
    }

    private enum Tags {
        static let sky = 8_101
        static let corona = 8_102
        static let body = 8_103
        static let launchReplica = 8_104
    }
}

/// Launch-safe fixed starfield. It intentionally mirrors StarfieldView but
/// resolves the launch tint explicitly so artwork recorded under the central
/// Luna unit-test host remains identical in every target.
private final class AppLaunchStarfieldView: UIView {
    private struct Star {
        let x: CGFloat
        let y: CGFloat
        let radius: CGFloat
        let alpha: CGFloat
        let bloom: Bool
    }

    private static let sky: [Star] = {
        var seed: UInt32 = 0x4C554E41
        func random() -> CGFloat {
            seed = seed &* 1_664_525 &+ 1_013_904_223
            return CGFloat(seed >> 8) / CGFloat(UInt32.max >> 8)
        }
        return (0..<170).map { index in
            let brightness = pow(random(), 3)
            return Star(
                x: random(), y: random(),
                radius: 0.40 + brightness * 0.65,
                alpha: 0.030 + brightness * 0.165,
                bloom: index % 19 == 0)
        }
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = true
        backgroundColor = .black
        isUserInteractionEnabled = false
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setFillColor(UIColor.black.cgColor)
        context.fill(bounds)
        context.setBlendMode(.screen)
        let tint = LunaSurfacePalette.blended(
            LunaSurfacePalette.atmosphereTint(for: .reader),
            toward: .white, amount: 0.55)
        for star in Self.sky {
            let center = CGPoint(x: star.x * bounds.width, y: star.y * bounds.height)
            if star.bloom {
                let radius = star.radius * 5
                if let gradient = CGGradient(
                    colorsSpace: CGColorSpaceCreateDeviceRGB(),
                    colors: [
                        tint.withAlphaComponent(star.alpha * 0.5).cgColor,
                        tint.withAlphaComponent(star.alpha * 0.14).cgColor,
                        tint.withAlphaComponent(0).cgColor,
                    ] as CFArray,
                    locations: [0, 0.4, 1]) {
                    context.drawRadialGradient(
                        gradient, startCenter: center, startRadius: 0,
                        endCenter: center, endRadius: radius, options: [])
                }
            }
            context.setFillColor(tint.withAlphaComponent(star.alpha).cgColor)
            context.fillEllipse(in: CGRect(
                x: center.x - star.radius, y: center.y - star.radius,
                width: star.radius * 2, height: star.radius * 2))
        }
    }
}
