//
//  InlineReaderEclipseTransition.swift
//  LunaReaderUI
//

import UIKit

/// Pure sizing policy for the nested-reader tab strip.
public struct InlineReaderTabMetrics: Equatable {
    public let tabWidth: CGFloat
    public let contentWidth: CGFloat
    public let initialContentOffsetX: CGFloat
    public let scrolls: Bool

    public init(availableWidth: CGFloat, tabCount: Int, minimumTabWidth: CGFloat) {
        let available = max(availableWidth, 0)
        let minimum = max(minimumTabWidth, 1)
        guard tabCount > 0 else {
            tabWidth = 0
            contentWidth = 0
            initialContentOffsetX = 0
            scrolls = false
            return
        }

        let equalWidth = available / CGFloat(tabCount)
        tabWidth = max(equalWidth, minimum)
        contentWidth = tabWidth * CGFloat(tabCount)
        initialContentOffsetX = max(contentWidth - available, 0)
        scrolls = contentWidth > available
    }
}

/// Pure rubber-band policy shared by top and bottom inline-reader dismissal.
public struct InlineReaderOverscrollMetrics: Equatable {
    public let progress: CGFloat
    public let commitsDismissal: Bool

    public init(distance: CGFloat, outwardVelocity: CGFloat) {
        progress = min(max(distance, 0) / 110, 1)
        commitsDismissal = progress >= 0.62 || outwardVelocity > 900
    }
}

/// One automatic, top-zenith solar eclipse used for both the first inline reader
/// and every deeper reader push. Only transforms and opacity animate: the costly
/// reader hierarchy is already laid out before the transition starts.
final class InlineReaderEclipseScene {
    static let duration: TimeInterval = 0.68

    private let container: UIView
    private let surface = UIView()
    private let circle = UIView()
    private let eclipse = UIView()
    private let corona = UIView()
    private let flare = InlineReaderZenithFlareView()
    private var completed = false

    init(container: UIView, sourcePoint: CGPoint, frame: CGRect? = nil) {
        self.container = container
        surface.frame = frame ?? container.bounds
        surface.clipsToBounds = true
        surface.isUserInteractionEnabled = false
        container.addSubview(surface)

        let localPoint = CGPoint(
            x: sourcePoint.x - surface.frame.minX,
            y: sourcePoint.y - surface.frame.minY)

        circle.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        circle.center = CGPoint(
            x: min(max(localPoint.x, 0), surface.bounds.width),
            y: min(max(localPoint.y, 0), surface.bounds.height))
        circle.backgroundColor = .black
        circle.layer.cornerRadius = 1
        circle.isUserInteractionEnabled = false
        surface.addSubview(circle)

        eclipse.frame = surface.bounds
        eclipse.backgroundColor = .black
        eclipse.layer.cornerRadius = 30
        eclipse.layer.cornerCurve = .continuous
        eclipse.transform = CGAffineTransform(translationX: 0, y: surface.bounds.height * 0.34)
        eclipse.alpha = 0
        eclipse.isUserInteractionEnabled = false
        surface.addSubview(eclipse)

        corona.frame = CGRect(x: 20, y: -2, width: max(surface.bounds.width - 40, 0), height: 4)
        corona.backgroundColor = .white
        corona.layer.cornerRadius = 2
        corona.layer.shadowColor = UIColor.white.cgColor
        corona.layer.shadowOpacity = 0.95
        corona.layer.shadowRadius = 26
        corona.layer.shadowOffset = .zero
        corona.alpha = 0
        eclipse.addSubview(corona)

        flare.bounds = CGRect(x: 0, y: 0, width: 112, height: 112)
        flare.center = CGPoint(x: eclipse.bounds.midX, y: 0)
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.42, y: 0.42)
        eclipse.addSubview(flare)
    }

    func animate(atZenith: @escaping () -> Void, completion: @escaping () -> Void) {
        if UIAccessibility.isReduceMotionEnabled {
            eclipse.transform = .identity
            eclipse.alpha = 1
            circle.transform = CGAffineTransform(scaleX: 2_000, y: 2_000)
            atZenith()
            UIView.animate(withDuration: 0.2, animations: {
                self.eclipse.alpha = 0
                self.circle.alpha = 0
            }, completion: { _ in
                self.finish(completion)
            })
            return
        }

        let point = circle.center
        let farthestX = max(point.x, surface.bounds.width - point.x)
        let farthestY = max(point.y, surface.bounds.height - point.y)
        let coverDiameter = hypot(farthestX, farthestY) * 2 + 8

        UIView.animateKeyframes(
            withDuration: Self.duration * 0.62,
            delay: 0,
            options: [.calculationModeCubic, .beginFromCurrentState]
        ) {
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                self.circle.transform = CGAffineTransform(
                    scaleX: coverDiameter / 2, y: coverDiameter / 2)
                self.eclipse.transform = .identity
                self.eclipse.alpha = 1
                self.eclipse.layer.cornerRadius = 0
            }
            UIView.addKeyframe(withRelativeStartTime: 0.66, relativeDuration: 0.34) {
                self.corona.alpha = 1
                self.flare.alpha = 1
                self.flare.transform = .identity
            }
        } completion: { _ in
            atZenith()
            UIView.animateKeyframes(
                withDuration: Self.duration * 0.38,
                delay: 0,
                options: [.calculationModeCubic]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.45) {
                    self.flare.alpha = 0
                    self.flare.transform = CGAffineTransform(scaleX: 1.35, y: 1.35)
                    self.corona.alpha = 0
                }
                UIView.addKeyframe(withRelativeStartTime: 0.34, relativeDuration: 0.66) {
                    self.eclipse.alpha = 0
                    self.circle.alpha = 0
                }
            } completion: { _ in
                self.finish(completion)
            }
        }
    }

    /// Runs the opening choreography backwards: the outgoing reader first
    /// dissolves into totality, then the eclipse drops away while the touch
    /// circle contracts back into the link that opened it.
    func animateReverse(
        hiding outgoingView: UIView,
        atZenith: @escaping () -> Void,
        completion: @escaping () -> Void
    ) {
        let point = circle.center
        let farthestX = max(point.x, surface.bounds.width - point.x)
        let farthestY = max(point.y, surface.bounds.height - point.y)
        let coverDiameter = hypot(farthestX, farthestY) * 2 + 8

        circle.transform = CGAffineTransform(scaleX: coverDiameter / 2, y: coverDiameter / 2)
        eclipse.transform = .identity
        eclipse.alpha = 1
        eclipse.layer.cornerRadius = 0
        container.bringSubviewToFront(outgoingView)

        atZenith()
        UIView.animate(
            withDuration: UIAccessibility.isReduceMotionEnabled ? 0.1 : Self.duration * 0.22,
            delay: 0,
            options: [.curveEaseIn, .beginFromCurrentState]
        ) {
            outgoingView.alpha = 0
        } completion: { _ in
            self.container.bringSubviewToFront(self.surface)
            guard !UIAccessibility.isReduceMotionEnabled else {
                self.eclipse.alpha = 0
                self.circle.alpha = 0
                self.finish(completion)
                return
            }

            self.corona.alpha = 1
            self.flare.alpha = 1
            self.flare.transform = .identity
            UIView.animateKeyframes(
                withDuration: Self.duration * 0.78,
                delay: 0,
                options: [.calculationModeCubic, .beginFromCurrentState]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.34) {
                    self.corona.alpha = 0
                    self.flare.alpha = 0
                    self.flare.transform = CGAffineTransform(scaleX: 0.42, y: 0.42)
                }
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 1) {
                    self.eclipse.transform = CGAffineTransform(
                        translationX: 0, y: self.surface.bounds.height * 0.34)
                    self.eclipse.alpha = 0
                    self.eclipse.layer.cornerRadius = 30
                    self.circle.transform = .identity
                }
            } completion: { _ in
                self.finish(completion)
            }
        }
    }

    private func finish(_ completion: () -> Void) {
        guard !completed else { return }
        completed = true
        surface.removeFromSuperview()
        completion()
    }
}

/// Compact diamond-ring flare whose zenith is the middle of the incoming
/// reader's top edge.
private final class InlineReaderZenithFlareView: UIView {
    override init(frame: CGRect) {
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
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2
        let colors = [
            UIColor.white.cgColor,
            UIColor.white.withAlphaComponent(0.8).cgColor,
            UIColor.white.withAlphaComponent(0.15).cgColor,
            UIColor.clear.cgColor,
        ] as CFArray
        if let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors,
            locations: [0, 0.07, 0.28, 1]) {
            context.drawRadialGradient(
                gradient, startCenter: center, startRadius: 0,
                endCenter: center, endRadius: radius, options: [])
        }

        context.setStrokeColor(UIColor.white.withAlphaComponent(0.86).cgColor)
        context.setLineWidth(1)
        for angle in stride(from: CGFloat.zero, to: .pi * 2, by: .pi / 4) {
            let length = angle.truncatingRemainder(dividingBy: .pi / 2) == 0 ? radius : radius * 0.55
            context.move(to: center)
            context.addLine(to: CGPoint(
                x: center.x + cos(angle) * length,
                y: center.y + sin(angle) * length))
        }
        context.strokePath()
    }
}

final class InlineReaderEclipseAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case forward, reverse }

    let sourcePoint: CGPoint
    let direction: Direction
    weak var sceneContainer: UIView?
    let sceneFrame: CGRect?
    var onTransitionStart: (() -> Void)?
    var atZenith: (() -> Void)?
    var onCompletion: (() -> Void)?

    init(
        sourcePoint: CGPoint,
        direction: Direction = .forward,
        sceneContainer: UIView? = nil,
        sceneFrame: CGRect? = nil,
        onTransitionStart: (() -> Void)? = nil,
        atZenith: (() -> Void)? = nil
    ) {
        self.sourcePoint = sourcePoint
        self.direction = direction
        self.sceneContainer = sceneContainer
        self.sceneFrame = sceneFrame
        self.onTransitionStart = onTransitionStart
        self.atZenith = atZenith
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        InlineReaderEclipseScene.duration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromController = transitionContext.viewController(forKey: .from),
              let toController = transitionContext.viewController(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }
        // Over-full-screen presentations are allowed to return nil for one of
        // these view lookups even though both controller views are available.
        let fromView = transitionContext.view(forKey: .from) ?? fromController.view!
        let toView = transitionContext.view(forKey: .to) ?? toController.view!

        let container = transitionContext.containerView
        let finalFrame = transitionContext.finalFrame(for: toController)
        // UIKit reports `.zero` for the retained presenting view during some
        // over-full-screen dismissals. Never collapse that reader behind the
        // receding eclipse.
        toView.frame = finalFrame.isEmpty ? container.bounds : finalFrame
        onTransitionStart?()

        switch direction {
        case .forward:
            toView.alpha = 0
            container.addSubview(toView)
            container.bringSubviewToFront(fromView)
            let scene = InlineReaderEclipseScene(
                container: sceneContainer ?? container, sourcePoint: sourcePoint,
                frame: sceneFrame)
            scene.animate(atZenith: { [weak self] in
                container.bringSubviewToFront(toView)
                toView.alpha = 0
                self?.atZenith?()
                UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
                    toView.alpha = 1
                }
            }, completion: { [weak self] in
                let completed = !transitionContext.transitionWasCancelled
                transitionContext.completeTransition(completed)
                if completed { self?.onCompletion?() }
            })

        case .reverse:
            toView.alpha = 1
            // A custom presentation keeps the presenting controller mounted
            // behind the transition container. Moving that live view into the
            // temporary container makes UIKit discard it when dismissal ends.
            // Only install it for navigation transitions where it is genuinely
            // absent from the hierarchy.
            if toView.window == nil, toView.superview == nil {
                container.insertSubview(toView, belowSubview: fromView)
            }
            let scene = InlineReaderEclipseScene(
                container: sceneContainer ?? container, sourcePoint: sourcePoint,
                frame: sceneFrame)
            scene.animateReverse(hiding: fromView, atZenith: { [weak self] in
                self?.atZenith?()
            }, completion: { [weak self] in
                let completed = !transitionContext.transitionWasCancelled
                // UIKit can retain the dismissed over-full-screen view until
                // the next transaction. Restore its model alpha before handing
                // the hierarchy back so it cannot leave the shared transition
                // container (or a cancelled dismissal) black.
                fromView.alpha = 1
                transitionContext.completeTransition(completed)
                if completed { self?.onCompletion?() }
            })
        }
    }
}
