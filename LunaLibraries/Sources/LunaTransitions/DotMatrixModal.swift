//
//  DotMatrixModal.swift
//  LunaTransitions
//
//  The Dot Matrix pixel-wipe for modal presentation and dismissal — alerts, action
//  sheets, bottom sheets, form sheets, popovers and full-screen covers, all through
//  one choreography that never fights UIKit's presentation controllers.
//
//  WHY NOT A UIViewControllerTransitioningDelegate (the removed first attempt): a
//  custom animator sees only the transition CONTAINER, which is empty for sheet/alert
//  presentations (the presenter's view stays outside it), so the "before" snapshot came
//  out blank; the dimming view and the sheet stack-back effect are private, animated by
//  the presentation controller alongside the animator, so they could only be guessed
//  at; and UIAlertController does not support replacing its transitioning delegate.
//  All of that produced the visual artifacts this rewrite removes.
//
//  HOW IT WORKS INSTEAD — the presentation really happens with `animated: false`
//  underneath an opaque, full-screen COVER WINDOW that shows a snapshot of the screen,
//  and the animation is played on top of that cover using genuinely-final pixels:
//
//   Present (partial-screen modal — alert / sheet / popover):
//     1. Snapshot the screen, show it on the cover, present unanimated beneath it.
//     2. REGION WIPE, immediately: the two-wave Metal dissolve runs confined to the
//        modal's frame (clipped to its rounded corners), from the old screen's pixels
//        to the committed modal. "Appear in place" modals (alerts, popovers, centred
//        sheets) use the random wavefront — scattered dots of the final UI appear at
//        their final position, then a second scattered wave sharpens them. "Movement"
//        modals (bottom sheets, action sheets, full covers) sweep both waves from the
//        edge the stock motion would have come from (up from the bottom on present,
//        back down on dismiss).
//     3. CHROME FADE, alongside the wipe: everything outside the modal's frame (the
//        dimming, a sheet's stack-back scale) crossfades from the old screen to the
//        new background — chrome never pixelates, mirroring the header/footer rule
//        elsewhere. The wipe leads rather than waits: everything before its first
//        frame is perceived tap latency.
//     4. The cover fades out over the live UI. The wipe's "after" texture was captured
//        from the real committed screen, so the reveal is pixel-exact.
//
//   Dismiss mirrors it: region wipe from the modal to the modal-free background first,
//   then the chrome (un-dim) fade.
//
//  Full-screen covers skip the chrome phase (there is no outside) and wipe the whole
//  screen, exactly like a nav push/pop but with the vertical wavefront.
//
//  Every guard falls back to the stock UIKit animation (toggle off, Metal missing,
//  remote/out-of-process content that can't be snapshotted, no window scene — e.g. app
//  extensions), and any mid-flight snapshot failure degrades to an instant cut with the
//  cover fading out, so the screen can never be left covered.
//

import LunaContentRendering
import LunaDesignSystem
import PhotosUI
import SafariServices
import UIKit

/// How the modal wipe should read. `.automatic` (the default) resolves from the
/// presentation's REAL resolved geometry after layout, so iPhone/iPad adaptations
/// (action sheet → popover, page sheet → centred sheet) pick the right feel for free.
public enum DotMatrixModalStyle {
    /// Resolve from the resolved frame: full-screen and bottom-anchored modals read as
    /// movement (vertical wave); centred/floating ones appear in place (random dots).
    case automatic
    /// Random dots materialise at the modal's final position, then sharpen — for
    /// alerts, popovers and anything that doesn't travel.
    case appearInPlace
    /// A single wavefront enters from the given edge (both waves travel the same way),
    /// for modals whose stock animation is a slide.
    case movement(present: DotMatrixWavefrontDirection, dismiss: DotMatrixWavefrontDirection)
}

/// The app-wide modal present/dismiss convenience — the Dot Matrix counterpart of
/// `present(_:animated:)` / `dismiss(animated:)`.
public enum DotMatrixModal {

    /// How long the non-pixelating chrome (dimming, stack-back) takes to fade — the
    /// "chrome fades, content wipes" budget shared by the region-confined surfaces
    /// (inline reader, lightbox, RabbitHole chrome).
    public static let chromeFadeDuration: TimeInterval = 0.12

    // Modals run on a compressed timing set — deliberately FASTER than every other
    // wipe: an alert or sheet blocks input, so it has to land quickly, while nav/
    // reader wipes can afford the full configured timeline.

    /// The modal wipe plays the global two-wave timeline at half its wall duration.
    private static var wipeDuration: TimeInterval {
        DotMatrixTransitionStyle.totalDuration * 0.5
    }
    /// The modal chrome (dimming) fade — quicker than the shared chrome budget.
    private static let modalChromeFadeDuration: TimeInterval = 0.08
    /// The final cover fade over the live UI. Softens anything the snapshots can't
    /// know about (shadows outside the region, content that moved mid-wipe).
    private static let revealFadeDuration: TimeInterval = 0.06

    // MARK: - Present

    /// Present `vc` from `presenter` behind the Dot Matrix pixel-wipe. Falls back to
    /// the stock UIKit animation whenever the wipe can't run (see file header).
    public static func present(_ vc: UIViewController,
                               from presenter: UIViewController,
                               animated: Bool = true,
                               style: DotMatrixModalStyle = .automatic,
                               completion: (() -> Void)? = nil) {
        guard animated, UIView.areAnimationsEnabled,
              DotMatrixTransitionCenter.shared.isEnabled,
              !containsRemoteContent(vc),
              presenter.presentedViewController == nil,
              let window = presenter.viewIfLoaded?.window,
              let scene = window.windowScene,
              let beforeFull = DotMatrixSnapshot.image(of: window, afterScreenUpdates: false)
        else {
            presenter.present(vc, animated: animated, completion: completion)
            return
        }

        let cover = DotMatrixCoverWindow(scene: scene, front: beforeFull)
        presenter.present(vc, animated: false) {
            window.layoutIfNeeded()
            guard let chrome = chromeView(of: vc),
                  let region = wipeRegion(for: chrome, in: window) else {
                teardown(cover, overlay: nil, window: window, fade: true, completion: completion)
                return
            }
            let directions = resolveDirections(style, for: vc, region: region, bounds: window.bounds)

            // Full-screen cover: no chrome outside the region, so it's one whole-screen
            // wipe from the old screen to the new — the modal twin of a nav push.
            if DotMatrixRegion.isFullScreen(region, bounds: window.bounds) {
                guard let after = DotMatrixSnapshot.image(of: window, afterScreenUpdates: true),
                      let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
                    teardown(cover, overlay: nil, window: window, fade: true, completion: completion)
                    return
                }
                install(overlay, frame: window.bounds, in: cover, traits: window.traitCollection,
                        direction: directions.present, before: beforeFull, after: after)
                overlay.animateProgress(to: 1, duration: wipeDuration) {
                    teardown(cover, overlay: overlay, window: window, fade: true, completion: completion)
                }
                return
            }

            // Partial-screen modal. The wipe starts FIRST — its before texture is the
            // old screen's region, pixel-identical to the cover beneath it, so the
            // overlay appears seamlessly — because every millisecond before it reads
            // as tap latency (UIKit's unanimated-present completion already burns a
            // few hundred, most of it keyboard bring-up when the modal has a field).
            guard let beforeRegion = DotMatrixSnapshot.crop(beforeFull, to: region),
                  let afterRegion = DotMatrixSnapshot.image(of: window, region: region,
                                                            afterScreenUpdates: true),
                  let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
                teardown(cover, overlay: nil, window: window, fade: true, completion: completion)
                return
            }
            install(overlay, frame: region, in: cover, traits: window.traitCollection,
                    direction: directions.present, corner: cornerAttributes(of: chrome),
                    before: beforeRegion, after: afterRegion)
            overlay.animateProgress(to: 1, duration: wipeDuration) {
                teardown(cover, overlay: overlay, window: window, fade: true, completion: completion)
            }

            // The chrome fade runs alongside the wipe: capture the modal-free
            // background (chrome briefly hidden — invisible under the cover, and the
            // overlay owns its region) and crossfade the surroundings from the old
            // screen to the real dimming/stack-back. If the snapshot fails the wipe
            // just finishes over the old chrome and teardown's cover fade reconciles
            // the rest — the screen is never left covered.
            chrome.alpha = 0
            let background = DotMatrixSnapshot.image(of: window, afterScreenUpdates: true)
            chrome.alpha = 1
            if let background {
                cover.backView.image = background
                UIView.animate(withDuration: modalChromeFadeDuration) {
                    cover.frontView.alpha = 0
                }
            }
        }
    }

    // MARK: - Dismiss

    /// Dismiss behind the pixel-wipe — the counterpart of `vc.dismiss(animated:)`,
    /// including its "dismiss the presented VC, or `vc` itself if it is the presented
    /// one" semantics. Falls back to the stock animation whenever the wipe can't run.
    public static func dismiss(_ vc: UIViewController,
                               animated: Bool = true,
                               style: DotMatrixModalStyle = .automatic,
                               completion: (() -> Void)? = nil) {
        // Resolve what actually gets dismissed: the VC presented on `vc`, or — when
        // `vc` is (inside) the presented one, e.g. a step pushed on a presented nav —
        // the presented ancestor itself.
        var presented = vc.presentedViewController ?? vc
        while let parent = presented.parent { presented = parent }
        guard animated, UIView.areAnimationsEnabled,
              DotMatrixTransitionCenter.shared.isEnabled,
              presented.presentingViewController != nil,
              presented.presentedViewController == nil,   // a stacked modal above would pop at reveal
              !containsRemoteContent(presented),
              let window = presented.viewIfLoaded?.window,
              let scene = window.windowScene,
              let chrome = chromeView(of: presented),
              let region = wipeRegion(for: chrome, in: window),
              let beforeFull = DotMatrixSnapshot.image(of: window, afterScreenUpdates: false)
        else {
            vc.dismiss(animated: animated, completion: completion)
            return
        }

        let directions = resolveDirections(style, for: presented, region: region, bounds: window.bounds)
        let isFull = DotMatrixRegion.isFullScreen(region, bounds: window.bounds)

        // The modal-free-but-still-dimmed background and the platter's rounding must
        // be captured while the modal is still presented (both are gone after the
        // dismissal commits).
        let corner = isFull ? nil : cornerAttributes(of: chrome)
        var background: UIImage?
        if !isFull {
            chrome.alpha = 0
            background = DotMatrixSnapshot.image(of: window, afterScreenUpdates: true)
            chrome.alpha = 1
            guard background != nil else {
                vc.dismiss(animated: animated, completion: completion)
                return
            }
        }

        let cover = DotMatrixCoverWindow(scene: scene, front: beforeFull)
        presented.dismiss(animated: false) {
            window.layoutIfNeeded()

            if isFull {
                guard let after = DotMatrixSnapshot.image(of: window, afterScreenUpdates: true),
                      let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
                    teardown(cover, overlay: nil, window: window, fade: true, completion: completion)
                    return
                }
                install(overlay, frame: window.bounds, in: cover, traits: window.traitCollection,
                        direction: directions.dismiss, before: beforeFull, after: after)
                overlay.animateProgress(to: 1, duration: wipeDuration) {
                    teardown(cover, overlay: overlay, window: window, fade: true, completion: completion)
                }
                return
            }

            // Phase 1 — region wipe: modal → the still-dimmed background.
            guard let background,
                  let beforeRegion = DotMatrixSnapshot.crop(beforeFull, to: region),
                  let backgroundRegion = DotMatrixSnapshot.crop(background, to: region),
                  let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: window) else {
                teardown(cover, overlay: nil, window: window, fade: true, completion: completion)
                return
            }
            install(overlay, frame: region, in: cover, traits: window.traitCollection,
                    direction: directions.dismiss, corner: corner,
                    before: beforeRegion, after: backgroundRegion)
            overlay.animateProgress(to: 1, duration: wipeDuration) {
                // Phase 2 — chrome fade: swap to the modal-free image (pixel-identical
                // to what's on screen: outside the region the two snapshots match, and
                // the overlay's final frame IS the background region), then fade the
                // whole cover to reveal the live, undimmed UI.
                cover.frontView.image = background
                cover.frontView.alpha = 1
                cover.backView.image = nil
                DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
                UIView.animate(withDuration: modalChromeFadeDuration, animations: {
                    cover.rootViewController?.view.alpha = 0
                }, completion: { _ in
                    teardown(cover, overlay: nil, window: window, fade: false, completion: completion)
                })
            }
        }
    }

    // MARK: - Style resolution

    /// Map a requested style onto concrete wavefront directions using the presented
    /// modal's RESOLVED geometry: full-screen and bottom-anchored-wide modals read as
    /// vertical movement (in from the bottom, out toward it); everything else — alerts,
    /// popovers, centred form sheets — appears in place with the random wavefront.
    private static func resolveDirections(_ style: DotMatrixModalStyle,
                                          for vc: UIViewController,
                                          region: CGRect,
                                          bounds: CGRect)
        -> (present: DotMatrixWavefrontDirection, dismiss: DotMatrixWavefrontDirection) {
        switch style {
        case .appearInPlace:
            return (.random, .random)
        case let .movement(present, dismiss):
            return (present, dismiss)
        case .automatic:
            if DotMatrixRegion.isFullScreen(region, bounds: bounds) {
                return vc.modalTransitionStyle == .crossDissolve
                    ? (.random, .random)
                    : (.bottomToTop, .topToBottom)
            }
            // Bottom sheets / action sheets sit flush with (or safe-area-inset from)
            // the bottom edge and span most of the width; those travel vertically.
            let nearBottom = region.maxY >= bounds.maxY - 80
            let wide = region.width >= bounds.width * 0.6
            if nearBottom && wide {
                return (.bottomToTop, .topToBottom)
            }
            return (.random, .random)
        }
    }

    // MARK: - Geometry

    /// A modal platter's corner rounding, applied to the overlay so the wipe clips to
    /// the modal's real shape — a hard rectangle would pixelate the background showing
    /// through the rounded corners.
    private struct CornerAttributes {
        let radius: CGFloat
        let corners: CACornerMask
        let curve: CALayerCornerCurve
    }

    /// Find the modal's rounding. UIKit puts the radius on the platter itself or on a
    /// platter-sized descendant (alerts round a backdrop, sheets the presented view),
    /// so walk a few levels down, following only views that still cover the platter.
    private static func cornerAttributes(of chrome: UIView) -> CornerAttributes? {
        var queue: [UIView] = [chrome]
        for _ in 0...3 {
            var next: [UIView] = []
            for view in queue {
                let frame = view.convert(view.bounds, to: chrome)
                guard frame.width >= chrome.bounds.width * 0.85,
                      frame.height >= chrome.bounds.height * 0.85 else { continue }
                if view.layer.cornerRadius > 0 {
                    return CornerAttributes(radius: view.layer.cornerRadius,
                                            corners: view.layer.maskedCorners,
                                            curve: view.layer.cornerCurve)
                }
                next.append(contentsOf: view.subviews)
            }
            if next.isEmpty { break }
            queue = next
        }
        return nil
    }

    /// The presentation's outermost own view inside the container — the presented view
    /// plus whatever platter/shadow wrapper UIKit put around it, but NOT the dimming
    /// (a sibling). Its frame is the wipe region; hiding it exposes the modal-free
    /// background (dimming included) for the chrome snapshots.
    private static func chromeView(of vc: UIViewController) -> UIView? {
        guard let pc = vc.presentationController,
              let presented = pc.presentedView ?? vc.viewIfLoaded else { return nil }
        guard let container = pc.containerView else { return presented }
        var view = presented
        while let superview = view.superview, superview !== container { view = superview }
        return view.superview === container ? view : presented
    }

    /// The modal's frame in window space, pixel-aligned (fractional origins would
    /// shear the overlay half a pixel off the live view and show a seam at reveal).
    private static func wipeRegion(for chrome: UIView, in window: UIWindow) -> CGRect? {
        let region = chrome.convert(chrome.bounds, to: window).integral
            .intersection(window.bounds)
        guard region.width > 1, region.height > 1 else { return nil }
        return region
    }

    /// Out-of-process content renders blank in `drawHierarchy` snapshots, so those
    /// presentations keep the stock animation (share sheet, Safari VC, system pickers).
    private static func containsRemoteContent(_ vc: UIViewController) -> Bool {
        if vc is UIActivityViewController || vc is SFSafariViewController
            || vc is PHPickerViewController || vc is UIDocumentPickerViewController
            || vc is UIImagePickerController {
            return true
        }
        if let nav = vc as? UINavigationController {
            return nav.viewControllers.contains(where: containsRemoteContent)
        }
        return false
    }

    // MARK: - Overlay + cover plumbing

    private static func install(_ overlay: RabbitHoleTransitionView,
                                frame: CGRect,
                                in cover: DotMatrixCoverWindow,
                                traits: UITraitCollection,
                                direction: DotMatrixWavefrontDirection,
                                corner: CornerAttributes? = nil,
                                before: UIImage,
                                after: UIImage) {
        overlay.style = DotMatrixTransitionStyleProvider.style(for: traits)
        overlay.direction = direction
        overlay.frame = frame
        overlay.autoresizingMask = []
        overlay.layer.cornerRadius = corner?.radius ?? 0
        overlay.layer.maskedCorners = corner?.corners
            ?? [.layerMinXMinYCorner, .layerMaxXMinYCorner,
                .layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        overlay.layer.cornerCurve = corner?.curve ?? .circular
        overlay.layer.masksToBounds = corner != nil
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        cover.contentView.addSubview(overlay)
        // A keyboard that rose during the unanimated present has been waiting under
        // its patch for this moment — its dissolve runs in step with the wipe.
        DotMatrixKeyboardReveal.modalWipeDidStart()
    }

    /// Retire the cover (fading it over the live UI unless told not to), return the
    /// overlay, then call the caller's completion. Every choreography path ends here,
    /// so the screen can never be left covered.
    private static func teardown(_ cover: DotMatrixCoverWindow,
                                 overlay: RabbitHoleTransitionView?,
                                 window: UIWindow?,
                                 fade: Bool,
                                 completion: (() -> Void)?) {
        let finish = {
            if let overlay {
                DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
            }
            if DotMatrixKeyboardReveal.activeCover === cover {
                DotMatrixKeyboardReveal.activeCover = nil
            }
            cover.isHidden = true
            cover.rootViewController = nil
            // A choreography that bailed before any wipe must still release a
            // deferred keyboard reveal (no-op when none is pending).
            DotMatrixKeyboardReveal.modalWipeDidStart()
            completion?()
        }
        guard fade else { finish(); return }
        UIView.animate(withDuration: revealFadeDuration, animations: {
            cover.rootViewController?.view.alpha = 0
        }, completion: { _ in finish() })
    }
}

/// The opaque, screen-sized window the choreography plays on. Sits just above the app
/// window (below the status bar and keyboard, which stay live), is never key, and
/// swallows touches for the wipe's duration like any transition. `frontView` fades
/// over `backView` for the chrome phases; the Metal overlay is added above both.
final class DotMatrixCoverWindow: UIWindow {

    let backView = UIImageView()
    let frontView = UIImageView()

    var contentView: UIView { rootViewController?.view ?? self }

    /// The full-window image currently showing — what a keyboard patch must copy so
    /// its pixels match the screen (see `DotMatrixKeyboardReveal.activeCover`).
    func visibleImage() -> UIImage? {
        if frontView.alpha > 0.5, let image = frontView.image { return image }
        return backView.image ?? frontView.image
    }

    init(scene: UIWindowScene, front: UIImage) {
        super.init(windowScene: scene)
        windowLevel = UIWindow.Level(UIWindow.Level.normal.rawValue + 50)
        backgroundColor = .clear
        AppearanceSettings.apply(to: self)

        let root = UIViewController()
        root.view.backgroundColor = .clear
        rootViewController = root
        for imageView in [backView, frontView] {
            imageView.frame = root.view.bounds
            imageView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            imageView.contentMode = .scaleToFill
            root.view.addSubview(imageView)
        }
        frontView.image = front
        isHidden = false
        // A keyboard rising during this choreography copies OUR pixels for its patch.
        DotMatrixKeyboardReveal.activeCover = self
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
