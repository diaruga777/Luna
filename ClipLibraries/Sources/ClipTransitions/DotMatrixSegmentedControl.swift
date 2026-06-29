//
//  DotMatrixSegmentedControl.swift
//  ClipTransitions
//
//  Plays a THREE-PHASE Dot Matrix pixel-wipe over a UISegmentedControl's OWN selection
//  change, so the moving selection indicator dissolves into dots, the dot cloud slides
//  from the prior segment to the new one, and then resolves back into the highlight —
//  instead of UIKit's stock slide. Pairs with a content-area DotMatrixCrossfade so the
//  control and the content it filters animate in the same idiom, while the surrounding
//  chrome (nav bar, large title, section headers) is left completely untouched.
//
//  The three phases:
//    1. PIXELATE the prior segment in place — the old highlight dissolves into dots in a
//       RANDOM (scattered) ordering.
//    2. MOVE the (fully pixelated) overlay's frame from the prior segment's rect to the
//       new segment's rect.
//    3. UNPIXELATE at the new segment — the dots resolve into the new highlight, again
//       in a RANDOM ordering.
//
//  `.valueChanged` fires AFTER the selection has moved, so the caller passes the
//  previously-selected index; the helper re-renders the old/new/no-selection states
//  (without animation, inside one runloop, so nothing flashes) to capture the snapshots
//  it dissolves between. Falls straight through to the stock instant selection move when
//  the pixel-wipe is disabled, the index is unchanged, or Metal/snapshots are unavailable.
//
//  REUSED BY: the reading-list filter (Task 2) AND the viewer mode switcher (Task 3) —
//  any `UISegmentedControl` whose selection moves between two segments. Keep the public
//  `animateSelectionChange(_:from:direction:)` signature stable for those callers.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public enum DotMatrixSegmentedControl {

    /// Dissolve `control` from its `previousIndex` selection to its current one with the
    /// three-phase pixel-wipe (pixelate prior → move → unpixelate new). `direction` is
    /// used for the pixelate/unpixelate phases and defaults to `.random` (scattered dot
    /// ordering, per spec). No-op — the stock instant selection move is already applied —
    /// when the wipe is off, the index is unchanged, or the control can't be snapshotted.
    ///
    /// Public + general so BOTH the reading-list filter and the viewer mode switcher can
    /// call it on any two-state `UISegmentedControl` selection change.
    public static func animateSelectionChange(_ control: UISegmentedControl,
                                              from previousIndex: Int,
                                              direction: DotMatrixWavefrontDirection = .random) {
        let newIndex = control.selectedSegmentIndex
        control.layoutIfNeeded()

        guard DotMatrixTransitionCenter.shared.isEnabled,
              previousIndex != newIndex,
              control.numberOfSegments > 0 else {
            return
        }

        // Snapshots: the live (new-selection) control, the prior-selection control, and a
        // no-selection ("cleared") control — all captured without animation in one runloop
        // so the on-screen state never flickers off the new selection.
        let liveSelection = control.selectedSegmentIndex
        var newImage: UIImage?
        var oldImage: UIImage?
        var clearedImage: UIImage?
        UIView.performWithoutAnimation {
            control.selectedSegmentIndex = newIndex
            control.layoutIfNeeded()
            newImage = DotMatrixSnapshot.image(of: control, afterScreenUpdates: false)

            control.selectedSegmentIndex = previousIndex
            control.layoutIfNeeded()
            oldImage = DotMatrixSnapshot.image(of: control, afterScreenUpdates: false)

            control.selectedSegmentIndex = UISegmentedControl.noSegment
            control.layoutIfNeeded()
            clearedImage = DotMatrixSnapshot.image(of: control, afterScreenUpdates: false)

            // Restore the live selection the value-change already committed.
            control.selectedSegmentIndex = liveSelection
            control.layoutIfNeeded()
        }

        guard let newImage, let oldImage, let clearedImage,
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: control.window) else {
            return
        }

        let bounds = control.bounds
        let oldRect = segmentRect(at: previousIndex, in: bounds, segments: control.numberOfSegments)
        let newRect = segmentRect(at: newIndex, in: bounds, segments: control.numberOfSegments)

        overlay.style = DotMatrixTransitionStyleProvider.style(for: control.traitCollection)
        overlay.direction = direction
        overlay.autoresizingMask = []
        overlay.isHidden = false
        control.addSubview(overlay)

        let window = control.window
        let phaseDuration = DotMatrixTransitionSettings.totalDuration / 3

        // Phase 1: pixelate the prior segment in place (old highlight → no-selection dots).
        overlay.frame = bounds
        overlay.configure(before: oldImage, after: clearedImage)
        overlay.setProgress(0)
        overlay.animateProgress(to: 1, duration: phaseDuration) {
            // Phase 2: slide the (cleared/pixelated) overlay from prior → new segment rect.
            // Hold the cleared state; only the FRAME moves. We crop the overlay to each
            // segment's rect so the dot cloud visibly travels.
            overlay.configure(before: clearedImage, after: clearedImage)
            overlay.setProgress(1)
            overlay.frame = oldRect
            UIView.animate(withDuration: phaseDuration, delay: 0, options: [.curveEaseInOut]) {
                overlay.frame = newRect
            } completion: { _ in
                // Phase 3: unpixelate at the new segment (no-selection dots → new highlight).
                overlay.frame = bounds
                overlay.configure(before: clearedImage, after: newImage)
                overlay.setProgress(0)
                overlay.animateProgress(to: 1, duration: phaseDuration) {
                    DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
                }
            }
        }
    }

    /// The rect of segment `index` within `bounds`, assuming equal-width segments. Pure
    /// and unit-testable. UISegmentedControl content-sized segments aren't exactly equal,
    /// but for the move phase an even division is a faithful, deterministic approximation
    /// (the dots only need to travel from roughly one segment to the next); an out-of-range
    /// index clamps to the bounds so the overlay never collapses to zero.
    public static func segmentRect(at index: Int, in bounds: CGRect, segments: Int) -> CGRect {
        guard segments > 0 else { return bounds }
        let clamped = min(max(index, 0), segments - 1)
        let width = bounds.width / CGFloat(segments)
        return CGRect(x: bounds.minX + CGFloat(clamped) * width,
                      y: bounds.minY, width: width, height: bounds.height)
    }
}
