//
//  HalftoneRabbitHoleTransition.swift
//  Clip
//
//  App-side implementation of the RabbitHole reader's transition, backed by the
//  pixel-mosaic Metal view. Lives in the app target because ClipReaderUI (compiled into
//  the extensions) can't link ClipContentRendering. Injected via ReaderHostFactory.
//

import ClipContentRendering
import ClipReaderUI
import UIKit

final class HalftoneRabbitHoleTransition: RabbitHoleTransitioning {

    /// Deliberately unhurried so the pixel dissolve reads clearly.
    private static let playDuration: TimeInterval = 0.9
    private static let settleDuration: TimeInterval = 0.5
    /// Mosaic block size in points.
    private static let pixelSize: CGFloat = 24

    func play(before: UIImage, after: UIImage,
              in container: UIView, completion: @escaping () -> Void) {
        guard let view = makeView(before: before, after: after, in: container) else {
            completion(); return   // Metal unavailable → instant cut
        }
        view.setProgress(0)
        view.animateProgress(to: 1, duration: Self.playDuration) {
            view.removeFromSuperview()
            completion()
        }
    }

    func begin(before: UIImage, after: UIImage,
               in container: UIView) -> RabbitHoleInteractiveTransition {
        guard let view = makeView(before: before, after: after, in: container) else {
            return NullInteractiveTransition()
        }
        view.setProgress(0)
        return InteractiveHandle(view: view, settleDuration: Self.settleDuration)
    }

    private func makeView(before: UIImage, after: UIImage,
                          in container: UIView) -> RabbitHoleTransitionView? {
        guard let view = RabbitHoleTransitionView.make() else { return nil }
        view.style = RabbitHoleTransitionStyle(pixelSize: Self.pixelSize, monochrome: false)
        view.frame = container.bounds
        view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        container.addSubview(view)
        container.layoutIfNeeded()   // give the metal layer its drawableSize first
        view.configure(before: before, after: after)
        return view
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
