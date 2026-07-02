//
//  DotMatrixRabbitHoleTransition.swift
//  Luna
//
//  App-side implementation of the RabbitHole reader's transition, backed by the
//  two-phase pixel-mosaic Metal view. Lives in the app target because LunaReaderUI
//  (compiled into the extensions) can't link LunaContentRendering. Injected via
//  ReaderHostFactory.
//
//  A single overlay view is built once and parked (hidden) in the reader's view, so a
//  dive/pop never pays the Metal setup cost mid-tap — see `prewarm`. Visual + timing
//  parameters come from `RabbitHoleTransitionSettings` (tunable in Experimental ▸
//  RabbitHole ▸ Transition Animation).
//
//  CONTENT WIPES, CHROME FADES: when the host supplies a `contentRegion` (the
//  destination focused layer's card below its floating header), only that sub-rect
//  pixelates — the Metal overlay is framed to it and fed region-relative CROPS of the
//  before/after images. The REST of the changed region (layer headers, lips, moving
//  card chrome) crossfades instead, on a pair of image views under the overlay: the
//  after image below, the before image above fading out — tracking the finger 1:1 in
//  the interactive pops. Without a contentRegion the whole region pixelates as before.
//

import LunaContentRendering
import LunaDesignSystem
import LunaReaderUI
import LunaTransitions
import UIKit

final class DotMatrixRabbitHoleTransition: RabbitHoleTransitioning {

    /// The reused overlay, parked hidden in the container between transitions.
    private var overlay: RabbitHoleTransitionView?

    func prewarm(in container: UIView) { _ = ensureOverlay(in: container, frame: nil) }

    func play(prepare: @escaping () -> (before: UIImage, after: UIImage),
              in container: UIView, region: CGRect?, contentRegion: CGRect?,
              completion: @escaping () -> Void) {
        guard ensureOverlay(in: container, frame: nil) != nil else {
            _ = prepare()   // wipe gated off → apply the state change, instant cut
            completion(); return
        }
        // The tap handler does NO heavy work — it only schedules this block. Until it
        // commits, the screen stays on the last-committed (pre-tap) frame, so there's no
        // visible lag or jank on tap. Here, on the next runloop, we take the before/after
        // snapshots and build the new layer, then bring up the GPU overlay at progress 0
        // (== the before frame) and animate — all batched into a single commit with the
        // overlay on top, so the build is never visible and the dissolve starts cleanly.
        // When `region` is given the overlay (and the host's before/after images) cover
        // only that sub-rect, so everything outside stays live and never pixelates.
        DispatchQueue.main.async {
            let frames = prepare()
            guard let stage = self.stage(before: frames.before, after: frames.after,
                                         in: container, region: region,
                                         contentRegion: contentRegion) else {
                completion(); return   // state already applied by prepare() — instant cut
            }
            container.layoutIfNeeded()
            // Chrome (headers, lips, card edges) fades on the same budget the other
            // "content wipes, chrome fades" surfaces use.
            if let chromeBefore = stage.chromeBefore {
                UIView.animate(withDuration: DotMatrixModal.chromeFadeDuration) {
                    chromeBefore.alpha = 0
                }
            }
            stage.overlay.animateProgress(to: 1, duration: DotMatrixTransitionSettings.totalDuration) {
                stage.tearDown()
                completion()
            }
        }
    }

    func begin(before: UIImage, after: UIImage,
               in container: UIView, region: CGRect?, contentRegion: CGRect?)
        -> RabbitHoleInteractiveTransition {
        guard let stage = stage(before: before, after: after, in: container,
                                region: region, contentRegion: contentRegion) else {
            return NullInteractiveTransition()
        }
        return InteractiveHandle(stage: stage,
                                 settleDuration: DotMatrixTransitionSettings.totalDuration)
    }

    // MARK: - Staging

    /// Everything one in-flight transition owns: the configured overlay (framed to the
    /// part that PIXELATES) and, when a `contentRegion` split the region, the two
    /// chrome crossfade image views (after below, before above) covering the rest.
    fileprivate struct Stage {
        let overlay: RabbitHoleTransitionView
        let chromeBefore: UIImageView?
        let chromeAfter: UIImageView?

        func tearDown() {
            chromeBefore?.removeFromSuperview()
            chromeAfter?.removeFromSuperview()
            DotMatrixRabbitHoleTransition.park(overlay)
        }
    }

    /// Configure the overlay (and, for a content-confined wipe, the chrome crossfade
    /// pair) at progress 0, ready to animate/drive. Returns nil when the wipe is gated
    /// off (see `ensureOverlay`) or the crops fail — callers fall back to an instant cut.
    private func stage(before: UIImage, after: UIImage,
                       in container: UIView, region: CGRect?,
                       contentRegion: CGRect?) -> Stage? {
        let effectiveRegion = (region ?? container.bounds).intersection(container.bounds)
        // The pixelating sub-rect. Degenerate/whole-region content rects collapse to
        // the plain single-overlay path (no chrome pair to fade).
        let wipeRect = contentRegion.map { $0.intersection(effectiveRegion).integral }
        let splitsChrome: Bool
        if let wipeRect, !wipeRect.isNull, wipeRect.width > 1, wipeRect.height > 1,
           !DotMatrixRegion.isFullScreen(wipeRect, bounds: effectiveRegion) {
            splitsChrome = true
        } else {
            splitsChrome = false
        }

        guard let view = ensureOverlay(in: container,
                                       frame: splitsChrome ? wipeRect : effectiveRegion) else {
            return nil
        }
        applyStyle(to: view)

        var chromeBefore: UIImageView?
        var chromeAfter: UIImageView?
        var wipeBefore = before
        var wipeAfter = after
        if splitsChrome, let wipeRect {
            // Region-relative crops feed the overlay; the full region images become the
            // chrome crossfade pair beneath it.
            let cropRect = wipeRect.offsetBy(dx: -effectiveRegion.minX, dy: -effectiveRegion.minY)
            guard let croppedBefore = DotMatrixSnapshot.crop(before, to: cropRect),
                  let croppedAfter = DotMatrixSnapshot.crop(after, to: cropRect) else {
                Self.park(view)
                return nil
            }
            wipeBefore = croppedBefore
            wipeAfter = croppedAfter

            let afterView = UIImageView(image: after)
            let beforeView = UIImageView(image: before)
            for (imageView, z) in [(afterView, 990.0), (beforeView, 991.0)] {
                imageView.frame = effectiveRegion
                imageView.contentMode = .scaleToFill
                imageView.layer.zPosition = CGFloat(z)   // under the overlay (1000)
                container.addSubview(imageView)
            }
            chromeAfter = afterView
            chromeBefore = beforeView
        }

        view.configure(before: wipeBefore, after: wipeAfter)
        view.setProgress(0)
        view.isHidden = false
        container.bringSubviewToFront(view)
        return Stage(overlay: view, chromeBefore: chromeBefore, chromeAfter: chromeAfter)
    }

    private func applyStyle(to view: RabbitHoleTransitionView) {
        view.style = DotMatrixTransitionStyleProvider.style(for: view.traitCollection)
        // The reader's dive/pop/overscroll is a stacked-layer reveal, not a strongly
        // directional motion, so it uses the random (fade-order) wavefront.
        view.direction = .random
    }

    /// Lazily build the overlay and (re)attach it on top of `container`, hidden, framed
    /// to `frame` (the sub-rect that pixelates) clamped to `container.bounds`; nil ⇒ the
    /// full bounds. The overlay carries no autoresizing in the framed case: it's
    /// reframed each call and must not stretch with the container.
    ///
    /// Returns nil — so callers fall back to a stock, no-wipe result — whenever the wipe
    /// is gated off: the animated-transitions preference, Reduce Motion, or Metal
    /// availability (all folded into `DotMatrixTransitionCenter.shared.isEnabled`). The
    /// check runs on every call (before any cached overlay) so flipping the preference or
    /// Reduce Motion takes effect on the very next dive/pop.
    @discardableResult
    private func ensureOverlay(in container: UIView, frame: CGRect?) -> RabbitHoleTransitionView? {
        guard DotMatrixTransitionCenter.shared.isEnabled else { return nil }
        let view: RabbitHoleTransitionView
        if let overlay {
            view = overlay
        } else {
            guard let made = RabbitHoleTransitionView.make() else { return nil }
            made.isHidden = true
            made.layer.zPosition = 1000   // above every layer card (which sit at z ≤ 0)
            overlay = made
            view = made
        }
        if view.superview !== container { view.removeFromSuperview(); container.addSubview(view) }
        container.bringSubviewToFront(view)
        if let frame, !frame.isNull {
            let rect = frame.intersection(container.bounds)
            view.frame = rect.isNull ? container.bounds : rect
            view.autoresizingMask = []
        } else {
            view.frame = container.bounds
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        }
        return view
    }

    /// Hide the overlay and drop its textures, leaving it in place for reuse.
    fileprivate static func park(_ view: RabbitHoleTransitionView) {
        view.isHidden = true
        view.clearTextures()
    }
}

/// Drives an in-flight interactive pixel-mosaic wipe. The chrome crossfade (headers,
/// lips) tracks the finger 1:1 alongside the overlay's progress.
private final class InteractiveHandle: RabbitHoleInteractiveTransition {
    private let stage: DotMatrixRabbitHoleTransition.Stage
    private let settleDuration: TimeInterval
    init(stage: DotMatrixRabbitHoleTransition.Stage, settleDuration: TimeInterval) {
        self.stage = stage
        self.settleDuration = settleDuration
    }

    func update(progress: CGFloat) {
        stage.overlay.setProgress(progress)
        stage.chromeBefore?.alpha = 1 - min(max(progress, 0), 1)
    }

    func finish(committed: Bool, completion: @escaping () -> Void) {
        if let chromeBefore = stage.chromeBefore {
            UIView.animate(withDuration: settleDuration) {
                chromeBefore.alpha = committed ? 0 : 1
            }
        }
        stage.overlay.animateProgress(to: committed ? 1 : 0, duration: settleDuration) { [stage] in
            stage.tearDown()
            completion()
        }
    }
}

/// No-op fallback when the wipe is gated off — the host still gets its completion so
/// it can place the final state (an instant cut).
private final class NullInteractiveTransition: RabbitHoleInteractiveTransition {
    func update(progress: CGFloat) {}
    func finish(committed: Bool, completion: @escaping () -> Void) { completion() }
}
