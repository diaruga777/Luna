//
//  HalftoneRabbitHoleTransition.swift
//  Clip
//
//  App-side implementation of the RabbitHole reader's transition, backed by the
//  two-phase pixel-mosaic Metal view. Lives in the app target because ClipReaderUI
//  (compiled into the extensions) can't link ClipContentRendering. Injected via
//  ReaderHostFactory.
//
//  A single overlay view is built once and parked (hidden) in the reader's view, so a
//  dive/pop never pays the Metal setup cost mid-tap — see `prewarm`. Visual + timing
//  parameters come from `RabbitHoleTransitionSettings` (tunable in Experimental ▸
//  RabbitHole ▸ Transition Animation).
//

import ClipContentRendering
import ClipReaderUI
import UIKit

final class HalftoneRabbitHoleTransition: RabbitHoleTransitioning {

    /// The reused overlay, parked hidden in the container between transitions.
    private var overlay: RabbitHoleTransitionView?

    func prewarm(in container: UIView) { _ = ensureOverlay(in: container) }

    func play(before: UIImage, after: UIImage,
              in container: UIView, completion: @escaping () -> Void) {
        guard let view = present(before: before, after: after, in: container) else {
            completion(); return   // Metal unavailable → instant cut
        }
        view.animateProgress(to: 1, duration: RabbitHoleTransitionSettings.totalDuration) {
            Self.park(view)
            completion()
        }
    }

    func begin(before: UIImage, after: UIImage,
               in container: UIView) -> RabbitHoleInteractiveTransition {
        guard let view = present(before: before, after: after, in: container) else {
            return NullInteractiveTransition()
        }
        return InteractiveHandle(view: view, settleDuration: RabbitHoleTransitionSettings.totalDuration)
    }

    /// Lazily build the overlay and (re)attach it on top of `container`, hidden.
    @discardableResult
    private func ensureOverlay(in container: UIView) -> RabbitHoleTransitionView? {
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
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        return view
    }

    /// Style + load the overlay for a transition and reveal it at progress 0.
    private func present(before: UIImage, after: UIImage,
                         in container: UIView) -> RabbitHoleTransitionView? {
        guard let view = ensureOverlay(in: container) else { return nil }
        view.style = RabbitHoleTransitionStyle(
            pixelSize: RabbitHoleTransitionSettings.pixelSize,
            stagger: RabbitHoleTransitionSettings.stagger,
            monochrome: RabbitHoleTransitionSettings.monochrome)
        view.phaseSplit = RabbitHoleTransitionSettings.phaseSplit
        container.layoutIfNeeded()   // give the metal layer its drawableSize first
        view.configure(before: before, after: after)
        view.setProgress(0)
        view.isHidden = false
        return view
    }

    /// Hide the overlay and drop its textures, leaving it in place for reuse.
    fileprivate static func park(_ view: RabbitHoleTransitionView) {
        view.isHidden = true
        view.clearTextures()
    }
}

/// Drives an in-flight interactive pixel-mosaic wipe.
private final class InteractiveHandle: RabbitHoleInteractiveTransition {
    private let view: RabbitHoleTransitionView
    private let settleDuration: TimeInterval
    init(view: RabbitHoleTransitionView, settleDuration: TimeInterval) {
        self.view = view
        self.settleDuration = settleDuration
    }

    func update(progress: CGFloat) { view.setProgress(progress) }

    func finish(committed: Bool, completion: @escaping () -> Void) {
        view.animateProgress(to: committed ? 1 : 0, duration: settleDuration) { [view] in
            HalftoneRabbitHoleTransition.park(view)
            completion()
        }
    }
}

/// No-op fallback when Metal is unavailable — the host still gets its completion so
/// it can place the final state (an instant cut).
private final class NullInteractiveTransition: RabbitHoleInteractiveTransition {
    func update(progress: CGFloat) {}
    func finish(committed: Bool, completion: @escaping () -> Void) { completion() }
}
