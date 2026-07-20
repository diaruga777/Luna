//
//  InlineReaderEclipseTransition.swift
//  LunaReaderUI
//
//  Stages the nested-reader push/pop as the same "solar eclipse" motif as two
//  other transitions. `CardEclipseAnimator` (LunaDesignSystem) stages the root
//  carousel's card-to-card paging; this file reuses its `CardEclipseTransition
//  .makeCorona` and `EclipseFlareView` directly for its own circle-reveal
//  choreography. `LunarEclipseTransition` (LunaTransitions) draws its own
//  corona and point light instead, since it eclipses an arbitrary snapshot
//  shape rather than a rounded card.
//

import LunaDesignSystem
import UIKit

/// Geometry contract fitting tabs plus a shortened inline card inside the
/// normal root-card footprint, keeping the persistent controls above clear.
public struct InlineReaderPresentationMetrics: Equatable {
    public let presentationFrameInWindow: CGRect
    public let cardFrameInWindow: CGRect
    public let localCardFrame: CGRect

    public init(cardFrameInWindow: CGRect, tabHeight: CGFloat) {
        let height = min(max(tabHeight, 0), max(cardFrameInWindow.height, 0))
        presentationFrameInWindow = cardFrameInWindow
        self.cardFrameInWindow = CGRect(
            x: cardFrameInWindow.minX,
            y: cardFrameInWindow.minY + height,
            width: cardFrameInWindow.width,
            height: max(cardFrameInWindow.height - height, 0))
        localCardFrame = CGRect(
            x: 0, y: height,
            width: cardFrameInWindow.width,
            height: max(cardFrameInWindow.height - height, 0))
    }
}

/// Pure sizing policy for the nested-reader tab strip.
public struct InlineReaderTabMetrics: Equatable {
    public let tabWidths: [CGFloat]
    public let contentWidth: CGFloat
    public let initialContentOffsetX: CGFloat
    public let scrolls: Bool

    public init(availableWidth: CGFloat, tabCount: Int, minimumTabWidth: CGFloat) {
        self.init(
            availableWidth: availableWidth,
            idealWidths: Array(repeating: availableWidth / CGFloat(max(tabCount, 1)), count: tabCount),
            minimumTabWidth: minimumTabWidth,
            spacing: 0)
    }

    public init(
        availableWidth: CGFloat,
        idealWidths: [CGFloat],
        minimumTabWidth: CGFloat,
        spacing: CGFloat
    ) {
        let available = max(availableWidth, 0)
        let minimum = max(minimumTabWidth, 1)
        guard !idealWidths.isEmpty else {
            tabWidths = []
            contentWidth = 0
            initialContentOffsetX = 0
            scrolls = false
            return
        }

        let spacingWidth = spacing * CGFloat(max(idealWidths.count - 1, 0))
        let clampedIdeals = idealWidths.map { max($0, minimum) }
        let idealTotal = clampedIdeals.reduce(0, +) + spacingWidth
        if idealTotal <= available {
            tabWidths = clampedIdeals
        } else {
            let equalWidth = max(
                (available - spacingWidth) / CGFloat(idealWidths.count), minimum)
            tabWidths = Array(repeating: equalWidth, count: idealWidths.count)
        }
        contentWidth = tabWidths.reduce(0, +) + spacingWidth
        initialContentOffsetX = max(contentWidth - available, 0)
        scrolls = contentWidth > available
    }

    /// Compatibility for callers that deliberately use equal-width tabs.
    public var tabWidth: CGFloat { tabWidths.first ?? 0 }
}

/// One automatic, top-zenith solar eclipse used for both the first inline reader
/// and every deeper reader push. Only transforms and opacity animate: the costly
/// reader hierarchy is already laid out before the transition starts.
final class InlineReaderEclipseScene {
    static let duration: TimeInterval = CardEclipseTransition.duration

    private let container: UIView
    private let surface = UIView()
    private let clippedSurface = UIView()
    private let circle = UIView()
    private let eclipse = UIView()
    private lazy var corona = CardEclipseTransition.makeCorona(frame: surface.bounds)
    private let flare = EclipseFlareView()
    private var completed = false

    init(container: UIView, sourcePoint: CGPoint, frame: CGRect? = nil) {
        self.container = container
        surface.frame = frame ?? container.bounds
        surface.clipsToBounds = false
        surface.isUserInteractionEnabled = false
        container.addSubview(surface)

        corona.alpha = 0
        surface.addSubview(corona)

        clippedSurface.frame = surface.bounds
        clippedSurface.clipsToBounds = true
        clippedSurface.layer.cornerRadius = CardSurfaceView.cornerRadius
        clippedSurface.layer.cornerCurve = .continuous
        surface.addSubview(clippedSurface)

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
        clippedSurface.addSubview(circle)

        eclipse.frame = surface.bounds
        eclipse.backgroundColor = .black
        eclipse.layer.cornerRadius = 30
        eclipse.layer.cornerCurve = .continuous
        eclipse.transform = CGAffineTransform(translationX: 0, y: surface.bounds.height * 0.34)
        eclipse.alpha = 0
        eclipse.isUserInteractionEnabled = false
        clippedSurface.addSubview(eclipse)

        flare.bounds = CGRect(x: 0, y: 0, width: 130, height: 130)
        flare.center = CGPoint(x: eclipse.bounds.midX, y: 0)
        flare.alpha = 0
        flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
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
            withDuration: Self.duration * 0.66,
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
            UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.8) {
                self.corona.alpha = 0.08
            }
            UIView.addKeyframe(withRelativeStartTime: 0.8, relativeDuration: 0.2) {
                self.corona.alpha = 1
            }
            UIView.addKeyframe(withRelativeStartTime: 0.82, relativeDuration: 0.18) {
                self.flare.alpha = 1
                self.flare.transform = .identity
            }
        } completion: { _ in
            atZenith()
            UIView.animateKeyframes(
                withDuration: Self.duration * 0.34,
                delay: 0,
                options: [.calculationModeCubic]
            ) {
                UIView.addKeyframe(withRelativeStartTime: 0, relativeDuration: 0.25) {
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
                    self.flare.transform = CGAffineTransform(scaleX: 0.45, y: 0.45)
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

final class InlineReaderEclipseAnimator: NSObject, UIViewControllerAnimatedTransitioning {
    enum Direction { case forward, reverse }

    let sourcePoint: CGPoint
    let direction: Direction
    weak var sceneContainer: UIView?
    let sceneFrame: CGRect?
    var onTransitionStart: (() -> Void)?
    var atZenith: (() -> Void)?

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
            }, completion: {
                let completed = !transitionContext.transitionWasCancelled
                transitionContext.completeTransition(completed)
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
            }, completion: {
                let completed = !transitionContext.transitionWasCancelled
                // UIKit can retain the dismissed over-full-screen view until
                // the next transaction. Restore its model alpha before handing
                // the hierarchy back so it cannot leave the shared transition
                // container (or a cancelled dismissal) black.
                fromView.alpha = 1
                transitionContext.completeTransition(completed)
            })
        }
    }
}
