//
//  CardExpandTransition.swift
//  LunaTransitions
//
//  The card-carousel's reader expansion: the pushed reader grows subtly from the
//  centered card's frame to fill the screen (corner radius relaxing to zero);
//  popping shrinks it back into the card. Mirrors the LunarEclipseTransitionCenter
//  association pattern — the carousel host arms the pushed reader with a closure
//  resolving the card's CURRENT frame, so the pop lands on the right card even
//  after paging or rotation.
//

import LunaDesignSystem
import ObjectiveC
import UIKit

public enum CardExpandTransitionCenter {
    private static var contextKey: UInt8 = 0

    private final class Context: NSObject {
        let sourceFrame: () -> CGRect?
        init(sourceFrame: @escaping () -> CGRect?) { self.sourceFrame = sourceFrame }
    }

    /// Arms `reader` (about to be pushed) with the expansion transition.
    /// `sourceFrame` returns the card's frame in the WINDOW's coordinate space
    /// (nil when the card is gone — the transition then falls back to default).
    public static func prepare(reader: UIViewController, sourceFrame: @escaping () -> CGRect?) {
        objc_setAssociatedObject(
            reader, &contextKey, Context(sourceFrame: sourceFrame),
            .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func animator(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController,
        to toViewController: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard !UIAccessibility.isReduceMotionEnabled else { return nil }
        switch operation {
        case .push:
            guard let context = objc_getAssociatedObject(toViewController, &contextKey) as? Context
            else { return nil }
            return CardExpandAnimator(direction: .expand, sourceFrame: context.sourceFrame)
        case .pop:
            guard let context = objc_getAssociatedObject(fromViewController, &contextKey) as? Context
            else { return nil }
            return CardExpandAnimator(direction: .contract, sourceFrame: context.sourceFrame)
        default:
            return nil
        }
    }
}

private final class CardExpandAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case expand, contract }

    private let direction: Direction
    private let sourceFrame: () -> CGRect?

    init(direction: Direction, sourceFrame: @escaping () -> CGRect?) {
        self.direction = direction
        self.sourceFrame = sourceFrame
    }

    func transitionDuration(using context: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.38
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to) else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let container = context.containerView
        let finalFrame = context.finalFrame(for: context.viewController(forKey: .to)!)
        let cardFrame = sourceFrame().map { container.convert($0, from: nil) }

        switch direction {
        case .expand:
            to.frame = finalFrame
            container.addSubview(to)
            to.layoutIfNeeded()
            let start = cardFrame ?? finalFrame.insetBy(
                dx: finalFrame.width * 0.06, dy: finalFrame.height * 0.06)
            // Grow the reader from the card's silhouette: transform (not frame)
            // so the fully laid-out screen scales as one, avoiding a relayout
            // at card size.
            to.transform = CGAffineTransform(
                scaleX: start.width / finalFrame.width,
                y: start.height / finalFrame.height)
            to.center = CGPoint(x: start.midX, y: start.midY)
            to.layer.cornerRadius = CarouselCardView.cornerRadius
            to.layer.cornerCurve = .continuous
            to.clipsToBounds = true
            UIView.animate(
                withDuration: transitionDuration(using: context),
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                to.transform = .identity
                to.center = CGPoint(x: finalFrame.midX, y: finalFrame.midY)
                to.layer.cornerRadius = 0
            } completion: { _ in
                to.clipsToBounds = false
                context.completeTransition(!context.transitionWasCancelled)
            }
        case .contract:
            to.frame = finalFrame
            container.insertSubview(to, belowSubview: from)
            let end = cardFrame ?? finalFrame.insetBy(
                dx: finalFrame.width * 0.06, dy: finalFrame.height * 0.06)
            from.clipsToBounds = true
            from.layer.cornerCurve = .continuous
            UIView.animate(
                withDuration: transitionDuration(using: context),
                delay: 0,
                options: [.curveEaseInOut]
            ) {
                from.transform = CGAffineTransform(
                    scaleX: end.width / finalFrame.width,
                    y: end.height / finalFrame.height)
                from.center = CGPoint(x: end.midX, y: end.midY)
                from.layer.cornerRadius = CarouselCardView.cornerRadius
                from.alpha = 0.02
            } completion: { _ in
                let completed = !context.transitionWasCancelled
                if !completed {
                    from.transform = .identity
                    from.frame = finalFrame
                    from.layer.cornerRadius = 0
                    from.alpha = 1
                    from.clipsToBounds = false
                }
                context.completeTransition(completed)
            }
        }
    }
}
