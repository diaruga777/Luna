//
//  HalftoneRabbitHoleTransition.swift
//  Clip
//
//  App-side implementation of the RabbitHole reader's transition, backed by the
//  halftone Metal view. Lives in the app target because ClipReaderUI (compiled into
//  the extensions) can't link ClipContentRendering. Injected via ReaderHostFactory.
//

import ClipContentRendering
import ClipReaderUI
import UIKit

final class HalftoneRabbitHoleTransition: RabbitHoleTransitioning {

    /// ~340ms dive/pop wipe — fast, just visibly perceptible.
    private static let playDuration: TimeInterval = 0.34
    private static let settleDuration: TimeInterval = 0.2

    func play(before: UIImage, after: UIImage, origin: CGPoint,
              in container: UIView, completion: @escaping () -> Void) {
        guard let view = makeView(before: before, after: after, origin: origin, in: container) else {
            completion(); return   // Metal unavailable → instant cut
        }
        view.setProgress(0)
        view.animateProgress(to: 1, duration: Self.playDuration) {
            view.removeFromSuperview()
            completion()
        }
    }

    func begin(before: UIImage, after: UIImage, origin: CGPoint,
               in container: UIView) -> RabbitHoleInteractiveTransition {
        guard let view = makeView(before: before, after: after, origin: origin, in: container) else {
            return NullInteractiveTransition()
        }
        view.setProgress(0)
        return InteractiveHandle(view: view, settleDuration: Self.settleDuration)
    }

    private func makeView(before: UIImage, after: UIImage, origin: CGPoint,
                          in container: UIView) -> RabbitHoleTransitionView? {
        guard let view = RabbitHoleTransitionView.make() else { return nil }
        view.style = Self.style()
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        container.layoutIfNeeded()   // give the metal layer its drawableSize first
        view.configure(before: before, after: after, origin: origin)
        return view
    }

    /// Comic/newsprint dots: circular, well-spaced, using the app's halftone cell size
    /// and gap colour so it sits in the same visual family as the Halftone effect.
    private static func style() -> RabbitHoleTransitionStyle {
        let config = HalftoneSettings.currentConfig
        return RabbitHoleTransitionStyle(
            cellSize: min(config.cellSize, 16),
            dotScale: config.dotScale,
            cornerRadius: 1.0,           // force circular dots
            edgeSoftness: config.edgeSoftness,
            gapColor: config.gapColor,
            monochrome: false)
    }
}

/// Drives an in-flight interactive halftone wipe.
private final class InteractiveHandle: RabbitHoleInteractiveTransition {
    private let view: RabbitHoleTransitionView
    private let settleDuration: TimeInterval
    init(view: RabbitHoleTransitionView, settleDuration: TimeInterval) {
        self.view = view
        self.settleDuration = settleDuration
    }

    func update(progress: CGFloat) { view.setProgress(progress) }

    func finish(committed: Bool, completion: @escaping () -> Void) {
        view.animateProgress(to: committed ? 1 : 0, duration: settleDuration) {
            self.view.removeFromSuperview()
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
