//
//  HalftoneBatch.swift
//  ClipTransitions
//
//  Plays the halftone pixel-wipe over a table view's visible area for animated row
//  insert/delete/reorder. The rows are updated WITHOUT the stock animation, then the
//  wipe dissolves the table's visible rect from its old layout to its new one. When the
//  pixel-wipe is disabled it falls back to an ordinary animated `performBatchUpdates`.
//

import ClipContentRendering
import ClipDesignSystem
import UIKit

@MainActor
public enum HalftoneBatch {
    /// Run `updates` (a `performBatchUpdates` body) under a halftone wipe. `direction`
    /// defaults to top-to-bottom, mirroring a list filling in.
    public static func update(_ table: UITableView,
                              direction: HalftoneWavefrontDirection = .topToBottom,
                              _ updates: () -> Void,
                              completion: ((Bool) -> Void)? = nil) {
        guard HalftoneTransitionCenter.shared.isEnabled,
              let host = table.superview,
              let before = HalftoneSnapshot.image(of: table, afterScreenUpdates: false) else {
            table.performBatchUpdates(updates, completion: completion)
            return
        }

        UIView.performWithoutAnimation {
            table.performBatchUpdates(updates, completion: nil)
        }
        table.layoutIfNeeded()

        guard let after = HalftoneSnapshot.image(of: table, afterScreenUpdates: true),
              let overlay = HalftoneTransitionCenter.shared.borrowOverlay(for: table.window) else {
            completion?(true); return
        }

        overlay.style = HalftoneTransitionStyleProvider.style(for: table.traitCollection)
        overlay.direction = direction
        overlay.frame = table.frame   // host coordinates
        host.addSubview(overlay)
        overlay.configure(before: before, after: after)
        overlay.setProgress(0)
        overlay.isHidden = false

        let window = table.window
        overlay.animateProgress(to: 1, duration: HalftoneTransitionSettings.totalDuration) {
            HalftoneTransitionCenter.shared.returnOverlay(overlay, for: window)
            completion?(true)
        }
    }
}
