//
//  LunarEclipseTransition.swift
//  LunaTransitions
//
//  A deliberately local navigation transition for opening a Reader item from a
//  reading-list row. It uses a rendered copy of the tapped row, so the eclipse has
//  the source's real silhouette rather than an approximation.

import LunaDesignSystem
import ObjectiveC
import UIKit

public enum LunarEclipseTransitionCenter {
    private static var contextKey: UInt8 = 0

    private final class Context: NSObject {
        weak var sourceView: UIView?
        init(sourceView: UIView) { self.sourceView = sourceView }
    }

    /// Records the row just before its reader is pushed. The association also marks
    /// the same reader for the matching reverse pop.
    public static func prepare(reader: UIViewController, sourceView: UIView) {
        objc_setAssociatedObject(reader, &contextKey, Context(sourceView: sourceView), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func animator(
        for operation: UINavigationController.Operation,
        from fromViewController: UIViewController,
        to toViewController: UIViewController
    ) -> UIViewControllerAnimatedTransitioning? {
        guard AppearanceSettings.lunarEclipseReaderTransitionEnabled,
              !UIAccessibility.isReduceMotionEnabled else { return nil }
        switch operation {
        case .push:
            guard let context = objc_getAssociatedObject(toViewController, &contextKey) as? Context,
                  let source = context.sourceView else { return nil }
            return LunarEclipseAnimator(direction: .push, sourceView: source)
        case .pop:
            guard objc_getAssociatedObject(fromViewController, &contextKey) as? Context != nil else { return nil }
            return LunarEclipseAnimator(direction: .pop, sourceView: fromViewController.view)
        default:
            return nil
        }
    }
}

private final class LunarEclipseAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case push, pop }

    // These are intentionally comparable to a stock push/pop. In a DEBUG simulator
    // launch, add -lunarEclipseSlowMotion to make each phase five times slower.
    private static var durationScale: TimeInterval {
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-lunarEclipseSlowMotion") ? 5 : 1
        #else
        return 1
        #endif
    }
    private let direction: Direction
    private weak var sourceView: UIView?

    init(direction: Direction, sourceView: UIView) {
        self.direction = direction
        self.sourceView = sourceView
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        0.58 * Self.durationScale
    }

    func animateTransition(using context: UIViewControllerContextTransitioning) {
        guard let from = context.view(forKey: .from), let to = context.view(forKey: .to) else {
            context.completeTransition(!context.transitionWasCancelled)
            return
        }
        let container = context.containerView
        let isPush = direction == .push
        if isPush { container.addSubview(to) }
        else { container.insertSubview(to, belowSubview: from) }
        to.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
        to.layoutIfNeeded()

        let dimmer = UIView(frame: container.bounds)
        dimmer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        container.addSubview(dimmer)

        let source = sourceView ?? from
        let sourceFrame = source.convert(source.bounds, to: container)
        let eclipse = makeEclipse(from: source, frame: sourceFrame)
        container.addSubview(eclipse)
        let travel = max(18, sourceFrame.width * 0.16) * (isPush ? -1 : 1)
        eclipse.transform = CGAffineTransform(translationX: travel, y: 0).scaledBy(x: 0.985, y: 0.985)
        eclipse.alpha = 0
        if !isPush { from.alpha = 1 }

        let duration = transitionDuration(using: context)
        UIView.animateKeyframes(withDuration: duration, delay: 0, options: [.calculationModeLinear]) {
            // Stage 1: the entire scene is swallowed by shadow.
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.43) { dimmer.alpha = 0.78 }
            // Stage 2: the slightly undersized black row crosses to its zenith.
            UIView.addKeyframe(withRelativeStartTime: 0.43, relativeDuration: 0.25) {
                eclipse.alpha = 1
                eclipse.transform = .identity
            }
            // Stage 3: a brief corona flash, then a slower uncovering of the destination.
            UIView.addKeyframe(withRelativeStartTime: 0.68, relativeDuration: 0.055) {
                dimmer.alpha = 0.96
                if !isPush { from.alpha = 0 }
            }
            UIView.addKeyframe(withRelativeStartTime: 0.735, relativeDuration: 0.265) {
                dimmer.alpha = 0
                eclipse.alpha = 0
            }
        } completion: { _ in
            let completed = !context.transitionWasCancelled
            if context.transitionWasCancelled { from.alpha = 1 }
            dimmer.removeFromSuperview()
            eclipse.removeFromSuperview()
            context.completeTransition(completed)
        }

    }

    private func makeEclipse(from source: UIView, frame: CGRect) -> UIView {
        let image = source.lunarEclipseSnapshot()
        let host = UIView(frame: frame)
        host.backgroundColor = .clear
        let silhouette = image?.withRenderingMode(.alwaysTemplate)
        let black = UIImageView(image: silhouette)
        black.tintColor = .black
        black.frame = host.bounds
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.layer.shadowColor = UIColor.white.cgColor
        black.layer.shadowRadius = 11
        black.layer.shadowOpacity = 0.82
        black.layer.shadowOffset = CGSize(width: direction == .push ? 4 : -4, height: 0)
        host.addSubview(black)

        // A narrow, clipped white crescent rides the leading edge; the shadow becomes
        // the full halo at zenith. The radial point makes the trailing/leading extreme
        // visibly brightest, matching push/pop direction respectively.
        let glow = UIImageView(image: silhouette)
        glow.tintColor = .white
        glow.frame = host.bounds
        glow.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        let crescent = CAGradientLayer()
        crescent.frame = glow.bounds
        crescent.startPoint = CGPoint(x: direction == .push ? 0 : 1, y: 0.5)
        crescent.endPoint = CGPoint(x: direction == .push ? 1 : 0, y: 0.5)
        crescent.colors = [UIColor.white.withAlphaComponent(0.94).cgColor, UIColor.clear.cgColor]
        crescent.locations = [0, 0.23]
        glow.layer.mask = crescent
        host.addSubview(glow)
        return host
    }
}

private extension UIView {
    func lunarEclipseSnapshot() -> UIImage? {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        format.scale = window?.screen.scale ?? UIScreen.main.scale
        return UIGraphicsImageRenderer(bounds: bounds, format: format).image { _ in
            drawHierarchy(in: bounds, afterScreenUpdates: false)
        }
    }
}
