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
        // Hide the destination before it enters the hierarchy. Adding it first leaves
        // UIKit one commit in which the fully laid-out reader can appear above the list.
        UIView.performWithoutAnimation {
            to.alpha = 0
            to.frame = context.finalFrame(for: context.viewController(forKey: .to)!)
            if isPush { container.addSubview(to) }
            else { container.insertSubview(to, belowSubview: from) }
            to.layoutIfNeeded()
        }

        let dimmer = UIView(frame: container.bounds)
        dimmer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        container.addSubview(dimmer)

        let source = sourceView ?? from
        let sourceFrame = source.convert(source.bounds, to: container)
        let (eclipse, corona, flare) = makeEclipse(from: source, frame: sourceFrame)
        container.addSubview(eclipse)
        let travel = max(18, sourceFrame.width * 0.16) * (isPush ? -1 : 1)
        eclipse.transform = CGAffineTransform(translationX: travel, y: 0).scaledBy(x: 0.985, y: 0.985)
        eclipse.alpha = 0
        corona.alpha = 0.15
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
        if !isPush { from.alpha = 1 }

        let duration = transitionDuration(using: context)
        let ingressDuration = duration * 0.68
        let egressDuration = duration - ingressDuration

        // Ingress ends at a genuinely opaque zenith. Keeping ingress and egress as
        // separate animators gives the view swap a real boundary instead of relying
        // on a zero-duration keyframe, which Core Animation may interpolate across.
        UIView.animateKeyframes(
            withDuration: ingressDuration,
            delay: 0,
            options: [.calculationModeCubic]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                dimmer.alpha = 1
                eclipse.alpha = 1
                eclipse.transform = .identity
                corona.alpha = 0.82
            }
            // A compact diamond-ring point blooms only as the leading edge reaches
            // zenith. It never paints white over the rest of the screen.
            UIView.addKeyframe(withRelativeStartTime: 0.76, relativeDuration: 0.24) {
                flare.alpha = 1
                flare.transform = .identity
            }
        } completion: { _ in
            // The black veil is now alpha 1, so this is the only moment at which the
            // navigation hierarchy changes which real screen is visible.
            UIView.performWithoutAnimation {
                to.alpha = 1
                if !isPush { from.alpha = 0 }
            }

            UIView.animateKeyframes(
                withDuration: egressDuration,
                delay: 0,
                options: [.calculationModeCubic]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    dimmer.alpha = 0
                    eclipse.alpha = 0
                    corona.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.22) {
                    flare.alpha = 0
                    flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                }
            } completion: { _ in
                let completed = !context.transitionWasCancelled
                if context.transitionWasCancelled { from.alpha = 1 }
                to.alpha = 1
                dimmer.removeFromSuperview()
                eclipse.removeFromSuperview()
                context.completeTransition(completed)
            }
        }
    }

    private func makeEclipse(from source: UIView, frame: CGRect) -> (UIView, UIView, UIView) {
        let image = source.lunarEclipseSnapshot()
        let host = UIView(frame: frame)
        host.backgroundColor = .clear
        host.clipsToBounds = false
        let silhouette = image?.withRenderingMode(.alwaysTemplate)

        // The corona is a radial point OUTSIDE the silhouette. Since it is below the
        // black body, no white is painted within the eclipse's bounds; a single point
        // at the directional extreme is brightest, falling off into the outer halo.
        let haloInset: CGFloat = 34
        let corona = UIView(frame: host.bounds.insetBy(dx: -haloInset, dy: -haloInset))
        corona.isUserInteractionEnabled = false
        let halo = CAGradientLayer()
        halo.type = .radial
        halo.frame = corona.bounds
        let brightPointX: CGFloat = direction == .push ? 0.90 : 0.10
        let edgeX: CGFloat = direction == .push ? 1.0 : 0.0
        halo.startPoint = CGPoint(x: brightPointX, y: 0.5)
        halo.endPoint = CGPoint(x: edgeX, y: 0.5)
        halo.colors = [UIColor.white.cgColor, UIColor.white.withAlphaComponent(0.28).cgColor, UIColor.clear.cgColor]
        halo.locations = [0, 0.24, 1]
        corona.layer.addSublayer(halo)
        host.addSubview(corona)

        let black = UIImageView(image: silhouette)
        black.tintColor = .black
        black.frame = host.bounds
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        black.layer.shadowColor = UIColor.white.cgColor
        // Keep the surrounding halo restrained: the radial corona above supplies the
        // one unmistakable peak rather than turning the whole leading edge white.
        black.layer.shadowRadius = 4
        black.layer.shadowOpacity = 0.08
        black.layer.shadowOffset = CGSize(width: direction == .push ? 4 : -4, height: 0)
        host.addSubview(black)

        let flareDiameter: CGFloat = 5
        let flare = UIView(frame: CGRect(
            x: direction == .push ? host.bounds.maxX - flareDiameter / 2 : -flareDiameter / 2,
            y: host.bounds.midY - flareDiameter / 2,
            width: flareDiameter,
            height: flareDiameter
        ))
        flare.isUserInteractionEnabled = false
        flare.backgroundColor = .white
        flare.layer.cornerRadius = flareDiameter / 2
        flare.layer.shadowColor = UIColor.white.cgColor
        flare.layer.shadowOpacity = 1
        flare.layer.shadowRadius = 15
        flare.layer.shadowOffset = .zero
        host.addSubview(flare)

        return (host, corona, flare)
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
