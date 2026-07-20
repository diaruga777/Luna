//
//  LunarEclipseTransition.swift
//  LunaTransitions
//
//  A deliberately local navigation transition for opening a Reader item from a
//  reading-list row. It uses a rendered copy of the tapped row, so the eclipse has
//  the source's real silhouette rather than an approximation.
//
//  Two other transitions stage the same "solar eclipse" motif for card-shaped
//  scenes: `CardEclipseAnimator` (LunaDesignSystem) for the root carousel's
//  paging, and `InlineReaderEclipseTransition` (LunaReaderUI), which reuses
//  that file's corona and flare drawing directly. This file draws its own
//  silhouette-shadow corona and radial-light point instead, because it
//  eclipses an arbitrary snapshot shape — a reading-list row, not a rounded
//  card — so it can't share those card-shaped primitives.

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

    // Keep simulator tuning deliberately slow. This is a compile-time branch so frame
    // inspection does not depend on a scheme argument surviving a Blitz/Xcode launch.
    private static var durationScale: TimeInterval {
        #if targetEnvironment(simulator)
        return 12
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
        container.addSubview(dimmer)

        let sourceIsFullScreen = sourceFrame.width >= container.bounds.width - 1
            && sourceFrame.height >= container.bounds.height - 1
        let (eclipse, corona, flare) = makeEclipse(
            from: source,
            frame: sourceFrame,
            sourceIsFullScreen: sourceIsFullScreen
        )
        container.addSubview(eclipse)
        let travel = isPush
            ? -max(18, sourceFrame.width * 0.16)
            : container.bounds.width
        eclipse.transform = CGAffineTransform(translationX: travel, y: 0)
        // The pop is a hard black slab crossing the already-dimmed scene. It must not
        // share the dimmer's fade or the leading edge becomes a grey dissolve.
        eclipse.alpha = isPush ? 0 : 1
        corona.alpha = isPush ? 0.2 : 1
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
                if isPush { eclipse.alpha = 1 }
                eclipse.transform = .identity
                corona.alpha = 1
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
                    if isPush {
                        eclipse.alpha = 0
                        corona.alpha = 0
                    } else {
                        // Continue the same right-to-left pass after zenith. Keeping
                        // alpha at one preserves the eclipse's hard black leading edge.
                        eclipse.transform = CGAffineTransform(
                            translationX: -container.bounds.width,
                            y: 0
                        )
                    }
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

    private func makeEclipse(
        from source: UIView,
        frame: CGRect,
        sourceIsFullScreen: Bool
    ) -> (UIView, UIView, UIView) {
        let image = source.lunarEclipseSnapshot()
        let host = UIView(frame: frame)
        host.backgroundColor = .clear
        host.clipsToBounds = false
        let silhouette = image?.withRenderingMode(.alwaysTemplate)

        // The flare is directional, but the corona belongs to the source silhouette:
        // outside compact views and inside views that fill the transition container.
        let lightCenter = CGPoint(
            x: sourceIsFullScreen ? min(42, host.bounds.width * 0.1) : host.bounds.maxX,
            y: host.bounds.midY
        )
        let corona = makeCorona(
            silhouette: silhouette,
            bounds: host.bounds,
            cornerRadius: source.layer.cornerRadius,
            sourceIsFullScreen: sourceIsFullScreen
        )
        let flare = makeRadialLight(
            diameter: sourceIsFullScreen ? 46 : 38,
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

        // Compact sources put the light below the body so the snapshot masks the
        // interior half and leaves only an exterior corona.
        if !sourceIsFullScreen {
            host.addSubview(corona)
            host.addSubview(flare)
        }

        let black = UIImageView(image: silhouette)
        black.tintColor = .black
        black.frame = host.bounds
        black.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.addSubview(black)

        // A full-screen eclipse puts its corona above the body on the interior side.
        if sourceIsFullScreen {
            host.addSubview(corona)
            host.addSubview(flare)
        }

        return (host, corona, flare)
    }

    private func makeCorona(
        silhouette: UIImage?,
        bounds: CGRect,
        cornerRadius: CGFloat,
        sourceIsFullScreen: Bool
    ) -> UIView {
        if sourceIsFullScreen {
            return EclipseInteriorCoronaView(cornerRadius: cornerRadius, frame: bounds)
        }

        // Rendering the white silhouette beneath the black body means only its
        // shadow escapes. The result follows the complete source outline instead of
        // collapsing into a second point light at the leading edge.
        let halo = UIImageView(image: silhouette)
        halo.frame = bounds
        halo.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        halo.tintColor = .white
        halo.clipsToBounds = false
        halo.layer.masksToBounds = false
        halo.layer.shadowColor = UIColor.white.cgColor
        halo.layer.shadowOpacity = 1
        halo.layer.shadowOffset = .zero
        halo.layer.shadowRadius = 22
        return halo
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

private final class EclipseInteriorCoronaView: UIView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat, frame: CGRect) {
        self.cornerRadius = cornerRadius
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        contentMode = .redraw
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.setBlendMode(.screen)

        // Nested translucent strokes create a glow that falls inward from every
        // source edge. The outermost stroke stays inside the full-screen bounds.
        let depth: CGFloat = 30
        let steps = 24
        for step in 0..<steps {
            let progress = CGFloat(step) / CGFloat(steps - 1)
            let inset = 1 + progress * depth
            let alpha = 0.42 * (1 - progress) * (1 - progress)
            let path = UIBezierPath(
                roundedRect: bounds.insetBy(dx: inset, dy: inset),
                cornerRadius: max(0, cornerRadius - inset)
            )
            context.setStrokeColor(UIColor.white.withAlphaComponent(alpha).cgColor)
            context.setLineWidth(2)
            context.addPath(path.cgPath)
            context.strokePath()
        }
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
