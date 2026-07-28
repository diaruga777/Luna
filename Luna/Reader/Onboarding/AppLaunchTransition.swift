//
//  AppLaunchTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

enum AppLaunchGeometry {
    static let referenceSize = CGSize(width: 402, height: 874)
    static let coronaReachRatio: CGFloat = 0.42
    static let rootCardHorizontalInset: CGFloat = 24
    static let rootCardBottomClearanceFromSafeArea: CGFloat = 116
    static let referenceSafeAreaBottomInset: CGFloat = 34

    /// The production Reader/onboarding card at rest on the launch-art
    /// recorder's reference iPhone. The launch storyboard constrains the black
    /// card to this same 24pt side inset, 9:16 aspect, and safe-area-relative
    /// bottom edge; only the corona is allowed to crop outside the display.
    static var referenceRootCardFrame: CGRect {
        let width = referenceSize.width - rootCardHorizontalInset * 2
        let height = width / CardCarouselMetrics.cardAspectRatio
        let bottom = referenceSize.height
            - referenceSafeAreaBottomInset
            - rootCardBottomClearanceFromSafeArea
        return CGRect(
            x: rootCardHorizontalInset,
            y: bottom - height,
            width: width,
            height: height)
    }

    /// Launch-safe approximation used only when a root has not yet exposed its
    /// real carousel frame. Width wins on phones; available safe-area height
    /// wins on compact-height and iPad layouts.
    static func fallbackRootCardFrame(
        in bounds: CGRect,
        safeAreaInsets: UIEdgeInsets
    ) -> CGRect {
        let preferredWidth = max(
            40, bounds.width - rootCardHorizontalInset * 2)
        let bottom = bounds.maxY
            - safeAreaInsets.bottom
            - rootCardBottomClearanceFromSafeArea
        let maximumHeight = max(
            40, bottom - bounds.minY - safeAreaInsets.top - 12)
        let height = min(
            preferredWidth / CardCarouselMetrics.cardAspectRatio,
            maximumHeight)
        let width = height * CardCarouselMetrics.cardAspectRatio
        return CGRect(
            x: bounds.midX - width / 2,
            y: bottom - height,
            width: width,
            height: height)
    }
}

/// The live first frame of every Luna app launch. The splash card is already
/// laid out at the destination deck's exact resting frame, so launch needs no
/// staged hold, resize, or eclipse egress—only one brief crossfade to the live
/// root hierarchy.
enum AppLaunchTransition {
    static let didFinish = Notification.Name("AppLaunchTransition.didFinish")
    static let fadeDuration: TimeInterval = 0.18

    static func install(in window: UIWindow) {
        window.layoutIfNeeded()
        guard window.bounds.width > 0, window.bounds.height > 0 else {
            DispatchQueue.main.async { install(in: window) }
            return
        }

        let rootView = window.rootViewController?.view
        rootView?.layoutIfNeeded()

        OnboardingAnimationClock.installSlowMotionIfRequested(in: window)
        let target = window.rootViewController?.appLaunchTransitionTarget()
        let targetFrame = target?.appLaunchTargetFrame(in: window)
            ?? fallbackTargetFrame(in: window)
        let overlay = makeLaunchView(frame: window.bounds, cardFrame: targetFrame)
        window.addSubview(overlay)

        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.10 : fadeDuration,
            delay: 0,
            options: [.curveEaseOut, .beginFromCurrentState]
        ) {
            overlay.alpha = 0
        } completion: { _ in
            overlay.removeFromSuperview()
            target?.appLaunchTransitionDidFinish()
            if target?.keepsOnboardingSlowMotionAfterLaunch != true {
                OnboardingAnimationClock.restoreNormalSpeed(in: window)
            }
            NotificationCenter.default.post(name: didFinish, object: nil)
        }
    }

    /// The first live splash frame. Its card frame comes directly from the
    /// destination carousel, making the fade geometrically stationary.
    static func makeLaunchView(frame: CGRect, cardFrame: CGRect) -> UIView {
        let overlay = UIView(frame: frame)
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = false

        let sky = AppLaunchStarfieldView(frame: overlay.bounds)
        sky.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(sky)

        let corona = EclipseCoronaView(
            bodySize: cardFrame.size,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint(for: .reader))
        corona.frame = cardFrame
        overlay.addSubview(corona)

        let body = CardSurfaceView(frame: cardFrame)
        body.backgroundColor = .black
        body.setBorderEnabled(true)
        let black = UIView(frame: body.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        body.installContentView(black)
        overlay.addSubview(body)
        body.layoutIfNeeded()
        corona.layoutIfNeeded()
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
        AppLaunchGeometry.fallbackRootCardFrame(
            in: window.bounds,
            safeAreaInsets: window.safeAreaInsets)
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
