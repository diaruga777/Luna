//
//  DotMatrixBatch.swift
//  ClipTransitions
//
//  Plays the Dot Matrix pixel-wipe over a table view's visible area for animated row
//  insert/delete/reorder. The rows are updated WITHOUT the stock animation, then the
//  wipe dissolves the table's visible rect from its old layout to its new one. When the
//  pixel-wipe is disabled it falls back to an ordinary animated `performBatchUpdates`.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

public enum DotMatrixBatch {
    /// Run `updates` (a `performBatchUpdates` body) under a Dot Matrix wipe. `direction`
    /// defaults to top-to-bottom, mirroring a list filling in.
    public static func update(_ table: UITableView,
                              direction: DotMatrixWavefrontDirection = .topToBottom,
                              _ updates: () -> Void,
                              completion: ((Bool) -> Void)? = nil) {
        guard DotMatrixTransitionCenter.shared.isEnabled,
              let host = table.superview,
              let before = DotMatrixSnapshot.image(of: table, afterScreenUpdates: false) else {
            table.performBatchUpdates(updates, completion: completion)
            return
        }

        UIView.performWithoutAnimation {
            table.performBatchUpdates(updates, completion: nil)
        }
        table.layoutIfNeeded()

        guard let after = DotMatrixSnapshot.image(of: table, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: table.window) else {
            completion?(true); return
        }

        overlay.style = DotMatrixTransitionStyleProvider.style(for: table.traitCollection)
        overlay.direction = direction
        overlay.frame = table.frame   // host coordinates
        host.addSubview(overlay)
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false

        let window = table.window
        overlay.animateProgress(to: 1, duration: DotMatrixTransitionSettings.totalDuration) {
            DotMatrixTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?(true)
        }
    }
}
