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

        let source = sourceView ?? from
        let sourceFrame = source.convert(source.bounds, to: container)

        let dimmer = UIView(frame: container.bounds)
        dimmer.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        dimmer.backgroundColor = .black
        dimmer.alpha = 0
        if isPush {
            // Keep the tapped row out of the veil. At zenith the black eclipse body
            // itself closes this hole, preserving a fully opaque handoff frame.
            let cutout = UIBezierPath(rect: dimmer.bounds)
            cutout.append(UIBezierPath(
                roundedRect: sourceFrame,
                cornerRadius: max(source.layer.cornerRadius, min(18, sourceFrame.height / 2))
            ))
            let mask = CAShapeLayer()
            mask.frame = dimmer.bounds
            mask.path = cutout.cgPath
            mask.fillRule = .evenOdd
            dimmer.layer.mask = mask
        }
        container.addSubview(dimmer)

        let (eclipse, corona, flare) = makeEclipse(from: source, frame: sourceFrame)
        container.addSubview(eclipse)
        let travel = max(18, sourceFrame.width * 0.16) * (isPush ? -1 : 1)
        // Translate at full size so the cutout exposes only the leading edge. Scaling
        // the body down creates a second, unnatural crescent on the trailing edge.
        eclipse.transform = CGAffineTransform(translationX: travel, y: 0)
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
            // zenith. Its radial falloff avoids a solid white disc or hard cutoff.
            UIView.addKeyframe(withRelativeStartTime: 0.76, relativeDuration: 0.24) {
                flare.alpha = 1
                flare.transform = .identity
            }
        } completion: { _ in
            // The black veil is now alpha 1, so this is the only moment at which the
            // navigation hierarchy changes which real screen is visible.
            UIView.performWithoutAnimation {
                // Seal the push cutout before changing screens. The egress should
                // uncover the destination uniformly from an entirely black frame.
                dimmer.layer.mask = nil
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

        let lightCenter = CGPoint(
            // A pop uses the full-screen source, so move the corona inward rather
            // than centring it beyond the left edge where it cannot be seen.
            x: direction == .push ? host.bounds.maxX : min(34, host.bounds.width * 0.085),
            y: host.bounds.midY
        )
        let corona = makeRadialLight(
            diameter: direction == .push ? 82 : 106,
            center: lightCenter,
            colors: [
                UIColor.white.withAlphaComponent(0.32),
                UIColor.white.withAlphaComponent(0.13),
                UIColor.clear
            ],
            locations: [0, 0.3, 1]
        )
        let flare = makeRadialLight(
            diameter: direction == .push ? 34 : 42,
            center: lightCenter,
            colors: [
                UIColor.white,
                UIColor.white.withAlphaComponent(0.86),
                UIColor.white.withAlphaComponent(0.34),
                UIColor.white.withAlphaComponent(0.08),
                UIColor.clear
            ],
            locations: [0, 0.04, 0.17, 0.43, 1]
        )

        // On push the light is below the body. The source snapshot's antialiased
        // silhouette naturally occludes its inner half instead of drawing a hard dot.
        if direction == .push {
            host.addSubview(corona)
            host.addSubview(flare)
        }

        let black = UIImageView(image: silhouette)
        black.tintColor = .black
        black.frame = host.bounds
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(black)

        // A pop's eclipse fills the host, so its glow must be above the body and
        // inset into the screen. Otherwise both light layers are clipped off-screen.
        if direction == .pop {
            host.addSubview(corona)
            host.addSubview(flare)
        }

        return (host, corona, flare)
    }

    private func makeRadialLight(
        diameter: CGFloat,
        center: CGPoint,
        colors: [UIColor],
        locations: [NSNumber]
    ) -> UIView {
        let light = EclipseRadialLightView(colors: colors, locations: locations)
        light.frame = CGRect(
            x: center.x - diameter / 2,
            y: center.y - diameter / 2,
            width: diameter,
            height: diameter
        )
        return light
    }
}

private final class EclipseRadialLightView: UIView {
    private let gradient: CGGradient?

    init(colors: [UIColor], locations: [NSNumber]) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let cgColors: [CGColor] = colors.map(\.cgColor)
        let stops: [CGFloat] = locations.map { CGFloat(truncating: $0) }
        gradient = CGGradient(
            colorsSpace: colorSpace,
            colors: cgColors as CFArray,
            locations: stops
        )
        super.init(frame: .zero)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let gradient, let context = UIGraphicsGetCurrentContext() else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        context.drawRadialGradient(
            gradient,
            startCenter: center,
            startRadius: 0,
            endCenter: center,
            endRadius: min(bounds.width, bounds.height) / 2,
            options: .drawsAfterEndLocation
        )
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
