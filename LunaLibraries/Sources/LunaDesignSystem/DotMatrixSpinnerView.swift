//
//  DotMatrixSpinnerView.swift
//  LunaDesignSystem
//
//  A Dot Matrix-flavored indeterminate spinner: a small grid of rounded-square
//  "dots" whose opacity + scale ripple in a continuous diagonal wave. It is a
//  mechanical drop-in for `UIActivityIndicatorView`
//  — same `startAnimating()` / `stopAnimating()` / `hidesWhenStopped` / `color`
//  surface, and it sizes itself via `intrinsicContentSize`.
//
//  Pure UIKit + Core Animation (per-dot `CALayer` driven by `CAKeyframeAnimation`),
//  so it is GPU-composited off the main thread and safe to use in the action/share
//  extensions (no Metal). Animations are added only while animating AND in a window,
//  and torn down when stopped or removed from the window, so a hidden/stopped
//  spinner costs nothing.
//

import QuartzCore
import UIKit

/// An indeterminate "dot-matrix" spinner. Drop-in replacement for
/// `UIActivityIndicatorView`.
public final class DotMatrixSpinnerView: UIView {

    // MARK: Configuration

    /// Number of dots per side of the (square) matrix.
    private let dimension: Int
    /// Overall side length of the spinner, in points.
    private let side: CGFloat
    /// Corner radius of each dot as a fraction of the dot's side (0…0.5).
    private let cornerRadiusFraction: CGFloat = 0.32
    /// Gap between dots as a fraction of a cell's side.
    private let spacingFraction: CGFloat = 0.28
    /// One full ripple cycle, in seconds.
    private let cycleDuration: CFTimeInterval = 1.1

    /// Mirrors `UIActivityIndicatorView.color` — the dot tint. Defaults to `LunaColors.primaryText`
    /// so it adapts to light/dark automatically.
    public var color: UIColor = LunaColors.primaryText {
        didSet { applyColor() }
    }

    /// Mirrors `UIActivityIndicatorView.hidesWhenStopped`. When true (default) the
    /// view hides itself while not animating.
    public var hidesWhenStopped: Bool = true {
        didSet {
            if hidesWhenStopped {
                if !isAnimating { isHidden = true }
            } else {
                isHidden = false
            }
        }
    }

    /// Whether the spinner is currently animating.
    public private(set) var isAnimating = false

    // MARK: Layers

    private var dotLayers: [CALayer] = []

    // MARK: Init

    /// - Parameters:
    ///   - dimension: dots per side (default 4 → a 4×4 matrix).
    ///   - side: overall side length in points (default 26).
    public init(dimension: Int = 4, side: CGFloat = 26) {
        self.dimension = max(2, dimension)
        self.side = max(8, side)
        super.init(frame: CGRect(x: 0, y: 0, width: self.side, height: self.side))
        commonInit()
    }

    public required init?(coder: NSCoder) {
        self.dimension = 4
        self.side = 26
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        isUserInteractionEnabled = false
        backgroundColor = .clear
        buildDots()
        applyColor()
        if hidesWhenStopped { isHidden = true }
    }

    // MARK: Layout

    public override var intrinsicContentSize: CGSize {
        CGSize(width: side, height: side)
    }

    public override func layoutSubviews() {
        super.layoutSubviews()
        layoutDots()
    }

    private func buildDots() {
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers = (0..<(dimension * dimension)).map { _ in
            let dot = CALayer()
            dot.opacity = baselineOpacity
            return dot
        }
        dotLayers.forEach { layer.addSublayer($0) }
    }

    /// The non-peak resting opacity of a dot (so the matrix is always faintly visible).
    private let baselineOpacity: Float = 0.25

    private func layoutDots() {
        // The available square is the smaller of the two dimensions, centered.
        let box = min(bounds.width, bounds.height)
        guard box > 0, dotLayers.count == dimension * dimension else { return }
        let originX = (bounds.width - box) / 2
        let originY = (bounds.height - box) / 2
        let cell = box / CGFloat(dimension)
        let dotSide = cell * (1 - spacingFraction)
        let radius = dotSide * cornerRadiusFraction
        let inset = (cell - dotSide) / 2

        for row in 0..<dimension {
            for column in 0..<dimension {
                let index = row * dimension + column
                let dot = dotLayers[index]
                dot.frame = CGRect(
                    x: originX + CGFloat(column) * cell + inset,
                    y: originY + CGFloat(row) * cell + inset,
                    width: dotSide,
                    height: dotSide
                )
                dot.cornerRadius = radius
            }
        }
    }

    private func applyColor() {
        let cg = color.resolvedColor(with: traitCollection).cgColor
        dotLayers.forEach { $0.backgroundColor = cg }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyColor()
        }
    }

    // MARK: Animation control

    /// Begins (or resumes) the ripple. Idempotent.
    public func startAnimating() {
        isAnimating = true
        if hidesWhenStopped { isHidden = false }
        addRippleAnimations()
    }

    /// Stops the ripple and, if `hidesWhenStopped`, hides the view.
    public func stopAnimating() {
        isAnimating = false
        removeRippleAnimations()
        if hidesWhenStopped { isHidden = true }
    }

    // MARK: Window lifecycle — pause off-window to save power

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            // Removed from a window: tear the animations down (but keep `isAnimating`
            // so re-attaching restores them).
            removeRippleAnimations()
        } else if isAnimating {
            addRippleAnimations()
        }
    }

    // MARK: Ripple

    /// Installs a staggered opacity+scale keyframe on each dot so a diagonal wave
    /// sweeps across the matrix forever. Driven entirely by Core Animation (no
    /// display link, no main-thread work per frame).
    private func addRippleAnimations() {
        guard window != nil else { return }
        layoutDots()
        let maxDistance = CGFloat((dimension - 1) * 2)   // top-left → bottom-right (row+col)

        for row in 0..<dimension {
            for column in 0..<dimension {
                let index = row * dimension + column
                let dot = dotLayers[index]
                // Diagonal phase: dots further along the diagonal lag in the cycle.
                let distance = CGFloat(row + column)
                let phase = maxDistance > 0 ? distance / maxDistance : 0
                // A negative time offset shifts each dot forward in the (repeating)
                // cycle, producing the travelling wave without per-frame work.
                let beginOffset = -CFTimeInterval(phase) * cycleDuration

                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                opacity.values = [baselineOpacity, 1.0, baselineOpacity]
                opacity.keyTimes = [0, 0.5, 1]

                let scale = CAKeyframeAnimation(keyPath: "transform.scale")
                scale.values = [0.7, 1.0, 0.7]
                scale.keyTimes = [0, 0.5, 1]

                let group = CAAnimationGroup()
                group.animations = [opacity, scale]
                group.duration = cycleDuration
                group.repeatCount = .infinity
                group.timeOffset = 0
                group.beginTime = CACurrentMediaTime() + beginOffset
                group.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                group.isRemovedOnCompletion = false

                dot.add(group, forKey: rippleKey)
            }
        }
    }

    private func removeRippleAnimations() {
        dotLayers.forEach { $0.removeAnimation(forKey: rippleKey) }
    }

    private let rippleKey = "dotMatrixRipple"

    // MARK: - Success beat: resolve into a checkmark

    /// The checkmark's polyline in unit-square coordinates (top-down, matching
    /// `layoutDots`'s row-major y axis: y=0 is the top row): a short downstroke
    /// then a long upstroke, i.e. a "✓".
    private static let checkmarkPolyline: [CGPoint] = [
        CGPoint(x: 0.18, y: 0.55), CGPoint(x: 0.42, y: 0.78), CGPoint(x: 0.82, y: 0.28),
    ]

    /// The unit-square center of dot `index` in a `dimension`×`dimension` grid —
    /// the same geometry `layoutDots` derives dot frames from.
    public static func cellCenter(dimension: Int, index: Int) -> CGPoint {
        guard dimension > 0 else { return .zero }
        let row = index / dimension
        let column = index % dimension
        let cell = 1 / CGFloat(dimension)
        return CGPoint(x: (CGFloat(column) + 0.5) * cell, y: (CGFloat(row) + 0.5) * cell)
    }

    /// Closest distance from `point` to the checkmark polyline, and how far along
    /// the total path length (0...total, not normalized) that closest point sits —
    /// the latter drives the per-dot stagger order in `resolveToCheckmark`.
    private static func closestPointOnCheckmark(_ point: CGPoint) -> (distance: CGFloat, position: CGFloat) {
        var bestDistance = CGFloat.greatestFiniteMagnitude
        var bestPosition: CGFloat = 0
        var lengthSoFar: CGFloat = 0
        for i in 0..<(checkmarkPolyline.count - 1) {
            let a = checkmarkPolyline[i]
            let b = checkmarkPolyline[i + 1]
            let ab = CGPoint(x: b.x - a.x, y: b.y - a.y)
            let segmentLength = hypot(ab.x, ab.y)
            let ap = CGPoint(x: point.x - a.x, y: point.y - a.y)
            let abLengthSquared = ab.x * ab.x + ab.y * ab.y
            let t = abLengthSquared > 0
                ? max(0, min(1, (ap.x * ab.x + ap.y * ab.y) / abLengthSquared)) : 0
            let closest = CGPoint(x: a.x + ab.x * t, y: a.y + ab.y * t)
            let distance = hypot(point.x - closest.x, point.y - closest.y)
            if distance < bestDistance {
                bestDistance = distance
                bestPosition = lengthSoFar + t * segmentLength
            }
            lengthSoFar += segmentLength
        }
        return (bestDistance, bestPosition)
    }

    /// Whether dot `index` lies near the checkmark polyline (within half a cell) —
    /// true for the dots that light up as the checkmark, false for everything else.
    /// Pure and side-effect free so the shape can be sanity-checked without a live
    /// view (used directly by `resolveToCheckmark`, and unit-tested on its own).
    public static func isCheckmarkDot(dimension: Int, index: Int) -> Bool {
        guard dimension > 0 else { return false }
        let cell = 1 / CGFloat(dimension)
        let center = cellCenter(dimension: dimension, index: index)
        return closestPointOnCheckmark(center).distance <= cell * 0.5
    }

    /// The dot's position along the checkmark stroke, normalized 0...1. Only
    /// meaningful for dots `isCheckmarkDot` accepts; used to order the per-dot "in"
    /// stagger so the checkmark appears to draw itself along the stroke.
    public static func checkmarkStrokePosition(dimension: Int, index: Int) -> CGFloat {
        let totalLength = (0..<(checkmarkPolyline.count - 1)).reduce(CGFloat(0)) { partial, i in
            partial + hypot(checkmarkPolyline[i + 1].x - checkmarkPolyline[i].x,
                             checkmarkPolyline[i + 1].y - checkmarkPolyline[i].y)
        }
        guard totalLength > 0 else { return 0 }
        let center = cellCenter(dimension: dimension, index: index)
        return closestPointOnCheckmark(center).position / totalLength
    }

    /// The success beat: stops the ripple, then animates the dots near the
    /// checkmark polyline to full opacity/scale (staggered along the stroke) while
    /// every other dot fades down to near-invisible — so the matrix visibly
    /// resolves into a "✓". Holds for `holdDuration` once the last dot settles,
    /// then calls `completion`. Pure Core Animation; total beat ≈ 0.5s at the
    /// defaults.
    public func resolveToCheckmark(holdDuration: TimeInterval = 0.35, completion: (() -> Void)? = nil) {
        isAnimating = false
        removeRippleAnimations()
        guard window != nil, dotLayers.count == dimension * dimension else {
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { completion?() }
            return
        }
        layoutDots()

        let checkmarkOrder = (0..<dotLayers.count)
            .filter { Self.isCheckmarkDot(dimension: dimension, index: $0) }
            .sorted {
                Self.checkmarkStrokePosition(dimension: dimension, index: $0)
                    < Self.checkmarkStrokePosition(dimension: dimension, index: $1)
            }
        let checkmarkSet = Set(checkmarkOrder)
        // Kept small: the mandated 0.35s hold already accounts for most of the
        // ≈0.5s total beat, so the stagger + resolve animation itself needs to
        // stay brisk even with a dozen-odd checkmark dots at dimension 7.
        let staggerStep: CFTimeInterval = 0.01
        let resolveDuration: CFTimeInterval = 0.12

        CATransaction.begin()
        CATransaction.setCompletionBlock {
            DispatchQueue.main.asyncAfter(deadline: .now() + holdDuration) { completion?() }
        }

        for (index, dot) in dotLayers.enumerated() {
            let isCheckmark = checkmarkSet.contains(index)
            let targetOpacity: Float = isCheckmark ? 1.0 : 0.08
            let targetScale: CGFloat = isCheckmark ? 1.05 : 0.6
            let delay: CFTimeInterval = isCheckmark
                ? CFTimeInterval(checkmarkOrder.firstIndex(of: index) ?? 0) * staggerStep : 0
            let currentScale = (dot.presentation()?.value(forKeyPath: "transform.scale") as? CGFloat) ?? 1.0

            let opacityAnim = CABasicAnimation(keyPath: "opacity")
            opacityAnim.fromValue = dot.presentation()?.opacity ?? dot.opacity
            opacityAnim.toValue = targetOpacity
            opacityAnim.beginTime = CACurrentMediaTime() + delay
            opacityAnim.duration = resolveDuration
            opacityAnim.fillMode = .forwards
            opacityAnim.isRemovedOnCompletion = false
            opacityAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let scaleAnim = CABasicAnimation(keyPath: "transform.scale")
            scaleAnim.fromValue = currentScale
            scaleAnim.toValue = targetScale
            scaleAnim.beginTime = CACurrentMediaTime() + delay
            scaleAnim.duration = resolveDuration
            scaleAnim.fillMode = .forwards
            scaleAnim.isRemovedOnCompletion = false
            scaleAnim.timingFunction = CAMediaTimingFunction(name: .easeOut)

            dot.opacity = targetOpacity
            dot.setValue(targetScale, forKeyPath: "transform.scale")
            dot.add(opacityAnim, forKey: "checkmarkOpacity")
            dot.add(scaleAnim, forKey: "checkmarkScale")
        }

        CATransaction.commit()
    }
}
