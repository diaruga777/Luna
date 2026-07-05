//
//  OnboardingDotMatrixBackdrop.swift
//  LunaSocialUI
//
//  An ambient dot-matrix panel that sits behind each onboarding step's icon or
//  illustration, tying the step visuals to the app's dot-matrix transition motif
//  (see `DotMatrixTransitionStyle` / `DotMatrixSpinnerView`). A slow diagonal
//  shimmer sweeps the grid; it is background texture, so both the resting
//  opacity and the shimmer peak are kept low enough not to compete with the
//  foreground illustration.
//
//  Pure Core Animation (per-dot `CALayer` + `CAKeyframeAnimation`, same
//  technique as `DotMatrixSpinnerView`) — GPU-composited, no per-frame main
//  thread work, cheap enough to run behind the nav pixel-wipe transitions.
//  Under Reduce Motion the grid renders static at its resting opacity.
//

import LunaDesignSystem
import QuartzCore
import UIKit

/// Ambient shimmer panel of dot-matrix dots, shown behind onboarding step visuals.
public final class OnboardingDotMatrixBackdrop: UIView {

    // Geometry: the transition tokens scaled ×2. At the literal 6pt/1pt transition
    // cell size a panel-sized grid needs ~1000 animated layers; doubling reads just
    // as "dot matrix" at a quarter of the layer count.
    private let dotSide: CGFloat = DotMatrixTransitionStyle.pixelSize * 2
    private let dotSpacing: CGFloat = DotMatrixTransitionStyle.spacing * 2
    private let dotCornerRadius: CGFloat = DotMatrixTransitionStyle.cornerRadius * 2

    /// Resting opacity of every dot — the static appearance under Reduce Motion.
    private let baselineOpacity: Float = 0.07
    /// Peak opacity a dot reaches as the shimmer wave passes over it.
    private let peakOpacity: Float = 0.16
    /// One full diagonal sweep of the panel, in seconds. Slow: ambient, not focal.
    private let cycleDuration: CFTimeInterval = 6.0

    private var dotLayers: [CALayer] = []
    private var gridSize: (columns: Int, rows: Int) = (0, 0)
    private var motionObserver: NSObjectProtocol?

    public init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        motionObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceMotionStatusDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.refreshShimmer() }
    }

    public required init?(coder: NSCoder) { fatalError("not used") }

    deinit {
        if let motionObserver { NotificationCenter.default.removeObserver(motionObserver) }
    }

    // MARK: Grid

    public override func layoutSubviews() {
        super.layoutSubviews()
        rebuildGridIfNeeded()
    }

    private func rebuildGridIfNeeded() {
        let pitch = dotSide + dotSpacing
        let columns = max(0, Int((bounds.width + dotSpacing) / pitch))
        let rows = max(0, Int((bounds.height + dotSpacing) / pitch))
        guard (columns, rows) != gridSize || dotLayers.count != columns * rows else {
            layoutGrid()
            return
        }
        gridSize = (columns, rows)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dotLayers.forEach { $0.removeFromSuperlayer() }
        dotLayers = (0..<(columns * rows)).map { _ in
            let dot = CALayer()
            dot.opacity = baselineOpacity
            dot.cornerRadius = dotCornerRadius
            dot.backgroundColor = UIColor.label.resolvedColor(with: traitCollection).cgColor
            layer.addSublayer(dot)
            return dot
        }
        layoutGrid()
        CATransaction.commit()
        refreshShimmer()
    }

    private func layoutGrid() {
        let (columns, rows) = gridSize
        guard columns > 0, rows > 0, dotLayers.count == columns * rows else { return }
        let pitch = dotSide + dotSpacing
        // Center the grid: distribute the leftover space so no dot is edge-clipped.
        let usedWidth = CGFloat(columns) * pitch - dotSpacing
        let usedHeight = CGFloat(rows) * pitch - dotSpacing
        let originX = (bounds.width - usedWidth) / 2
        let originY = (bounds.height - usedHeight) / 2

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for row in 0..<rows {
            for column in 0..<columns {
                dotLayers[row * columns + column].frame = CGRect(
                    x: originX + CGFloat(column) * pitch,
                    y: originY + CGFloat(row) * pitch,
                    width: dotSide, height: dotSide)
            }
        }
        CATransaction.commit()
    }

    private func applyColor() {
        let cg = UIColor.label.resolvedColor(with: traitCollection).cgColor
        dotLayers.forEach { $0.backgroundColor = cg }
    }

    public override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        if traitCollection.hasDifferentColorAppearance(comparedTo: previous) {
            applyColor()
        }
    }

    // MARK: Shimmer

    public override func didMoveToWindow() {
        super.didMoveToWindow()
        refreshShimmer()
    }

    /// Installs or removes the shimmer to match the current window / Reduce Motion
    /// state. Animations only affect the presentation layer — the model layer stays
    /// at `baselineOpacity`, so offscreen snapshots (`layer.render(in:)`) are
    /// deterministic.
    private func refreshShimmer() {
        removeShimmer()
        guard window != nil, !UIAccessibility.isReduceMotionEnabled else { return }
        addShimmer()
    }

    private func addShimmer() {
        let (columns, rows) = gridSize
        guard columns > 0, rows > 0 else { return }
        let maxDistance = CGFloat(max(columns + rows - 2, 1))

        for row in 0..<rows {
            for column in 0..<columns {
                let dot = dotLayers[row * columns + column]
                // Diagonal phase, exactly as in DotMatrixSpinnerView: a negative
                // begin-time offset shifts each dot forward in the repeating cycle.
                let phase = CGFloat(row + column) / maxDistance
                let beginOffset = -CFTimeInterval(phase) * cycleDuration

                let opacity = CAKeyframeAnimation(keyPath: "opacity")
                // Brief brighten as the wavefront passes, then rest for the cycle's
                // remainder — a travelling sweep rather than constant blinking.
                opacity.values = [baselineOpacity, peakOpacity, baselineOpacity, baselineOpacity]
                opacity.keyTimes = [0, 0.06, 0.14, 1]
                opacity.duration = cycleDuration
                opacity.repeatCount = .infinity
                opacity.beginTime = CACurrentMediaTime() + beginOffset
                opacity.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                opacity.isRemovedOnCompletion = false
                dot.add(opacity, forKey: shimmerKey)
            }
        }
    }

    private func removeShimmer() {
        dotLayers.forEach { $0.removeAnimation(forKey: shimmerKey) }
    }

    private let shimmerKey = "onboardingBackdropShimmer"
}
