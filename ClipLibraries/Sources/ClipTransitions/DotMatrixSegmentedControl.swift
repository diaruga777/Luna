//
//  DotMatrixSegmentedControl.swift
//  ClipTransitions
//
//  Plays the Dot Matrix pixel-wipe over a UISegmentedControl's OWN selection change, so
//  the moving selection indicator (and any per-segment highlight) dissolves dot-by-dot
//  instead of UIKit's stock slide. Pairs with a content-area DotMatrixCrossfade so the
//  control and the content it filters animate in the same idiom — while the surrounding
//  chrome (nav bar, large title, section headers) is left completely untouched.
//
//  `.valueChanged` fires AFTER the selection has moved, so the caller passes the
//  previously-selected index; the helper briefly re-renders the old selection (without
//  animation) to capture the "before" snapshot, restores the new one, and dissolves
//  between the two on a borrowed overlay. Falls through to nothing (the stock instant
//  selection move) when the pixel-wipe is disabled or unavailable.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public enum DotMatrixSegmentedControl {
    /// Dissolve `control` from its `previousIndex` selection to its current one with the
    /// pixel-wipe. No-op (stock behaviour already applied) when the wipe is off, the index
    /// is unchanged, or the control can't be snapshotted.
    public static func animateSelectionChange(_ control: UISegmentedControl,
                                              from previousIndex: Int,
                                              direction: DotMatrixWavefrontDirection = .random) {
        let newIndex = control.selectedSegmentIndex
        control.layoutIfNeeded()

        guard DotMatrixTransitionCenter.shared.isEnabled,
              previousIndex != newIndex,
              let after = DotMatrixSnapshot.image(of: control, afterScreenUpdates: false) else {
            return
        }

        // Re-render the OLD selection (no animation) to grab the "before" image, then snap
        // straight back to the live state — both happen inside one runloop so nothing
        // flashes on screen.
        var before: UIImage?
        UIView.performWithoutAnimation {
            control.selectedSegmentIndex = previousIndex
            control.layoutIfNeeded()
            before = DotMatrixSnapshot.image(of: control, afterScreenUpdates: false)
            control.selectedSegmentIndex = newIndex
            control.layoutIfNeeded()
        }

        guard let before,
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: control.window) else {
            return
        }

        overlay.style = DotMatrixTransitionStyleProvider.style(for: control.traitCollection)
        overlay.direction = direction
        overlay.frame = control.bounds
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false
        control.addSubview(overlay)

        let window = control.window
        overlay.animateProgress(to: 1, duration: DotMatrixTransitionSettings.totalDuration) {
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
        }
    }
}
