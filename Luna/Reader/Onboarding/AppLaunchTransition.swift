//
//  AppLaunchTransition.swift
//  Luna
//

import LunaDesignSystem
import UIKit

/// Where the launch splash draws, and what it draws there.
///
/// The card frame itself is not this type's business — it is
/// `CardDeckGeometry.cardFrame(inScreenSize:safeAreaInsets:)`, the same pure
/// function the live deck's constraints reproduce. What lives here is the
/// splash's own geometry: the reference canvas the artwork is recorded on, and
/// the corona's throw past the card.
///
/// This used to be three constants (`rootCardHorizontalInset`,
/// `rootCardBottomClearanceFromSafeArea`, `referenceSafeAreaBottomInset`)
/// hand-copied from the ARTICLE card's layout and measured on one iPhone, plus a
/// "launch-safe approximation" (`fallbackRootCardFrame`) used on every other
/// device. Both are gone: there is one card frame, and it is exact everywhere.
enum AppLaunchGeometry {
    /// The phone the artwork is recorded at. Nothing depends on it being this
    /// device — the rasters are scaled to the card frame wherever they land —
    /// but recording at a real shipping geometry keeps the artwork's aspect
    /// honest.
    static let referenceSize = CGSize(width: 402, height: 874)
    static let referenceSafeAreaInsets = UIEdgeInsets(
        top: 62, left: 0, bottom: 34, right: 0)

    /// The card the artwork is recorded around.
    static var referenceRootCardFrame: CGRect {
        CardDeckGeometry.cardFrame(
            inScreenSize: referenceSize, safeAreaInsets: referenceSafeAreaInsets)
    }

    /// How far the splash corona throws past the card's limb, as a fraction of
    /// the card's WIDTH.
    ///
    /// `EclipseCorona.reach` is `0.42 × shortest side` with a 150pt ceiling, and
    /// the ceiling is why this is stated separately: a ratio that changes with
    /// the card size cannot be carried by one raster. Pinning the fraction makes
    /// the splash artwork uniformly scalable — one image, exact on every screen
    /// — and on the reference phone it resolves to the same throw the clamped
    /// formula gives, because the clamp does not bind at a phone's card width.
    static let coronaReachFraction: CGFloat = 0.42

    /// The corona artwork's frame for a card at `cardFrame`: the card grown by
    /// its proportional reach on all four sides. Crops off the display on
    /// purpose — the light does not stop at the bezel.
    static func coronaFrame(forCardFrame cardFrame: CGRect) -> CGRect {
        let reach = coronaReach(forCardWidth: cardFrame.width)
        return cardFrame.insetBy(dx: -reach, dy: -reach)
    }

    static func coronaReach(forCardWidth width: CGFloat) -> CGFloat {
        width * coronaReachFraction
    }

    /// The corona artwork's width as a multiple of the card's — what the launch
    /// storyboard multiplies its card guide by, since it cannot call this.
    static var coronaWidthMultiple: CGFloat { 1 + coronaReachFraction * 2 }

    /// The corona artwork's own width:height. Constant, because both the card's
    /// aspect and the reach fraction are.
    static var coronaAspectRatio: CGFloat {
        let cardHeightMultiple = 1 / CardCarouselMetrics.cardAspectRatio
        return coronaWidthMultiple / (cardHeightMultiple + coronaReachFraction * 2)
    }
}

/// The live first frame of every Luna app launch. The splash card is already
/// laid out at the destination deck's exact resting frame, so launch needs no
/// staged hold, resize, or eclipse egress—only one brief crossfade to the live
/// root hierarchy.
enum AppLaunchTransition {
    static let didFinish = Notification.Name("AppLaunchTransition.didFinish")
    /// True once the launch crossfade has retired. It is what separates "this
    /// appearance IS the launch" from "the user navigated here": the util card's
    /// intro headline sweeps only in the former, and simply stands revealed when
    /// paged back to.
    private(set) static var hasFinished = false
    static let minimumVisibleDuration: TimeInterval = 0.10
    static let fadeDuration: TimeInterval = 0.20
    /// For a target whose live hierarchy is pixel-identical to the splash
    /// (incomplete onboarding: same starfield, corona, and blank black card),
    /// the crossfade reveals nothing and only needs to mask sub-pixel
    /// differences — one visible splash frame, then the quickest possible fade.
    static let instantMinimumVisibleDuration: TimeInterval = 0.02
    static let instantFadeDuration: TimeInterval = 0.05

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
        overlay.setNeedsLayout()
        overlay.layoutIfNeeded()

        // Do not begin the fade in the same run-loop turn that installs the
        // splash. On a warm/fast launch Core Animation can otherwise commit
        // only the final alpha, producing a plain black frame with no eclipse.
        // (An instant-reveal target keeps its own corona, so it only needs the
        // next turn, not a guaranteed eclipse beat.)
        let instant = target?.prefersInstantLaunchReveal == true
        let hold = instant ? instantMinimumVisibleDuration : minimumVisibleDuration
        let fade: TimeInterval = instant
            ? instantFadeDuration
            : (UIAccessibility.isReduceMotionEnabled ? 0.10 : fadeDuration)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + OnboardingAnimationClock.delay(hold)
        ) {
            guard overlay.window != nil else { return }
            target?.appLaunchTransitionWillReveal()
            UIView.animate(
                withDuration: fade,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                overlay.alpha = 0
            } completion: { _ in
                overlay.removeFromSuperview()
                hasFinished = true
                target?.appLaunchTransitionDidFinish()
                if target?.keepsOnboardingSlowMotionAfterLaunch != true {
                    OnboardingAnimationClock.restoreNormalSpeed(in: window)
                }
                NotificationCenter.default.post(name: didFinish, object: nil)
            }
        }
    }

    /// The first live splash frame: the same two layers the launch STORYBOARD
    /// shows, at the same geometry, so the system's launch screen and the app's
    /// own first frame are one picture and the crossfade has nothing to reveal.
    static func makeLaunchView(frame: CGRect, cardFrame: CGRect) -> UIView {
        let overlay = UIView(frame: frame)
        overlay.backgroundColor = .black
        overlay.isUserInteractionEnabled = false

        let sky = AppLaunchStarfieldView(frame: overlay.bounds)
        sky.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.addSubview(sky)

        let corona = makeCoronaCardView(cardFrame: cardFrame)
        overlay.addSubview(corona)
        return overlay
    }

    /// The recorded corona-and-card artwork, sized to `cardFrame`.
    ///
    /// It used to be a live `EclipseCoronaView`, rendered fresh at every launch
    /// and again for onboarding's persistent corona. Two things were wrong with
    /// that. It is not free — the exterior corona is ~80ms of stroked offset
    /// curves at 1x on a simulator, on the launch path, three times over — and
    /// 1x is exactly what made the splash look soft: the recorded artwork is
    /// baked at 3x from a 1x render, so its streamer wedges arrived as 3x3
    /// blocks. Drawing the artwork instead costs nothing, is sharp, and is
    /// identical to the launch screen by construction rather than by agreement.
    ///
    /// The view's own bounds are the CARD's, with the artwork overhanging on
    /// every side, so callers position it exactly as they position the card.
    static func makeCoronaCardView(cardFrame: CGRect) -> UIView {
        let container = UIView(frame: cardFrame)
        container.isUserInteractionEnabled = false
        container.clipsToBounds = false
        container.backgroundColor = .clear

        let artwork = UIImageView(image: launchCoronaCardArtwork)
        artwork.frame = container.bounds.insetBy(
            dx: -AppLaunchGeometry.coronaReach(forCardWidth: cardFrame.width),
            dy: -AppLaunchGeometry.coronaReach(forCardWidth: cardFrame.width))
        // Fixed (negative) margins with a flexible core: the overhang stays put
        // when the card resizes.
        artwork.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        artwork.contentMode = .scaleToFill
        container.addSubview(artwork)
        return container
    }

    /// The one raster, shared by the launch overlay, onboarding's intro corona
    /// and the util card's. Loose in the bundle rather than in the asset
    /// catalog, and single-scale rather than 1x/2x/3x: the launch screen needs
    /// it before the app has started, and it is always drawn at an explicitly
    /// computed frame, so one generously-sized image downscales to every device
    /// instead of a 2x variant being upscaled on the largest iPad.
    static let coronaCardArtworkName = "LunaLaunchCoronaCard"
    static let starfieldArtworkName = "LunaLaunchStarfield"

    private static let launchCoronaCardArtwork = UIImage(named: coronaCardArtworkName)

    /// Renders the corona-and-card artwork: the corona at `artworkScale`, the
    /// black card body, and its rim, on a canvas that is exactly
    /// `AppLaunchGeometry.coronaFrame`. Called by the recorder only.
    static func makeCoronaCardArtworkView(cardFrame: CGRect) -> UIView {
        let coronaFrame = AppLaunchGeometry.coronaFrame(forCardFrame: cardFrame)
        let canvas = UIView(frame: CGRect(origin: .zero, size: coronaFrame.size))
        canvas.backgroundColor = .clear
        canvas.isOpaque = false

        let body = CGRect(
            x: cardFrame.minX - coronaFrame.minX,
            y: cardFrame.minY - coronaFrame.minY,
            width: cardFrame.width,
            height: cardFrame.height)
        let corona = EclipseCoronaView(
            bodySize: body.size,
            cornerRadius: CardSurfaceView.cornerRadius,
            tint: LunaSurfacePalette.atmosphereTint(for: .reader),
            reach: AppLaunchGeometry.coronaReach(forCardWidth: cardFrame.width),
            scale: EclipseCorona.artworkScale)
        corona.frame = body
        canvas.addSubview(corona)

        let surface = CardSurfaceView(frame: body)
        surface.backgroundColor = .black
        surface.setBorderEnabled(true)
        let black = UIView(frame: surface.bounds)
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.backgroundColor = .black
        surface.installContentView(black)
        canvas.addSubview(surface)
        canvas.layoutIfNeeded()
        surface.layoutIfNeeded()
        corona.layoutIfNeeded()
        return canvas
    }

    static func makeStaticStarfieldView(frame: CGRect) -> UIView {
        AppLaunchStarfieldView(frame: frame)
    }

    private static func fallbackTargetFrame(in window: UIWindow) -> CGRect {
        CardDeckGeometry.cardFrame(
            inScreenSize: window.bounds.size,
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
