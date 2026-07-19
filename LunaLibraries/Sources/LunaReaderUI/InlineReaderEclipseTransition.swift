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

/// One automatic, top-zenith solar eclipse used for both the first inline reader
/// and every deeper reader push. Only transforms and opacity animate: the costly
/// reader hierarchy is already laid out before the transition starts.
final class InlineReaderEclipseScene {
    static let duration: TimeInterval = 0.68

    private let container: UIView
    private let circle = UIView()
    private let eclipse = UIView()
    private let corona = UIView()
    private let flare = InlineReaderZenithFlareView()
    private var completed = false

    init(container: UIView, sourcePoint: CGPoint) {
        self.container = container

        circle.bounds = CGRect(x: 0, y: 0, width: 2, height: 2)
        circle.center = CGPoint(
            x: min(max(sourcePoint.x, 0), container.bounds.width),
            y: min(max(sourcePoint.y, 0), container.bounds.height))
        circle.backgroundColor = .black
        circle.layer.cornerRadius = 1
        circle.isUserInteractionEnabled = false
        container.addSubview(circle)

        eclipse.frame = container.bounds
        eclipse.backgroundColor = .black
        eclipse.layer.cornerRadius = 30
        eclipse.layer.cornerCurve = .continuous
        eclipse.transform = CGAffineTransform(translationX: 0, y: container.bounds.height * 0.34)
        eclipse.alpha = 0
        eclipse.isUserInteractionEnabled = false
        container.addSubview(eclipse)

        corona.frame = CGRect(x: 20, y: -2, width: max(container.bounds.width - 40, 0), height: 4)
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
        let farthestX = max(point.x, container.bounds.width - point.x)
        let farthestY = max(point.y, container.bounds.height - point.y)
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

    private func finish(_ completion: () -> Void) {
        guard !completed else { return }
        completed = true
        circle.removeFromSuperview()
        eclipse.removeFromSuperview()
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
    let sourcePoint: CGPoint
    weak var sceneContainer: UIView?
    var atZenith: (() -> Void)?

    init(
        sourcePoint: CGPoint,
        sceneContainer: UIView? = nil,
        atZenith: (() -> Void)? = nil
    ) {
        self.sourcePoint = sourcePoint
        self.sceneContainer = sceneContainer
        self.atZenith = atZenith
    }

    func transitionDuration(using transitionContext: UIViewControllerContextTransitioning?) -> TimeInterval {
        InlineReaderEclipseScene.duration
    }

    func animateTransition(using transitionContext: UIViewControllerContextTransitioning) {
        guard let fromView = transitionContext.view(forKey: .from),
              let toView = transitionContext.view(forKey: .to) else {
            transitionContext.completeTransition(false)
            return
        }

        let container = transitionContext.containerView
        toView.frame = transitionContext.finalFrame(
            for: transitionContext.viewController(forKey: .to)!)
        toView.alpha = 0
        container.addSubview(toView)
        container.bringSubviewToFront(fromView)

        let scene = InlineReaderEclipseScene(
            container: sceneContainer ?? container, sourcePoint: sourcePoint)
        scene.animate(atZenith: { [weak self] in
            container.bringSubviewToFront(toView)
            toView.alpha = 0
            self?.atZenith?()
            UIView.animate(withDuration: 0.14, delay: 0, options: [.curveEaseOut]) {
                toView.alpha = 1
            }
        }, completion: {
            fromView.removeFromSuperview()
            transitionContext.completeTransition(!transitionContext.transitionWasCancelled)
        })
    }
}
