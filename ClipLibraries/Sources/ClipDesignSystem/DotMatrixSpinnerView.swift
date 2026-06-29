//
//  DotMatrixSpinnerView.swift
//  ClipDesignSystem
//
//  A Dot Matrix-flavored indeterminate spinner: a small grid of rounded-square
//  "dots" whose opacity + scale ripple in a continuous diagonal wave. It evokes
//  the app's dot-matrix transition aesthetic (rounded squares, small spacing,
//  monochrome label tint) and is a mechanical drop-in for `UIActivityIndicatorView`
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

    /// Mirrors `UIActivityIndicatorView.color` — the dot tint. Defaults to `.label`
    /// so it adapts to light/dark automatically.
    public var color: UIColor = .label {
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
}
