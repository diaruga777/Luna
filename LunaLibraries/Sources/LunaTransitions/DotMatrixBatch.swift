//
//  DotMatrixBatch.swift
//  LunaTransitions
//
//  Plays the Dot Matrix pixel-wipe over a table view's visible area for animated row
//  insert/delete/reorder. The rows are updated WITHOUT the stock animation, then the
//  wipe dissolves the table's visible rect from its old layout to its new one. When the
//  pixel-wipe is disabled it falls back to an ordinary animated `performBatchUpdates`.
//
//  `region` (in the TABLE's own coordinate space) confines the wipe to just the changed
//  rows' bounding rect — derive it with `DotMatrixRegion.changedRegion(...)` from the
//  before/after row frames so genuinely-unchanged rows never pixelate. nil = the whole
//  visible table (the original behaviour).
//

import LunaContentRendering
import LunaDesignSystem
import UIKit

public enum DotMatrixBatch {
    /// Run `updates` (a `performBatchUpdates` body) under a Dot Matrix wipe. `direction`
    /// defaults to top-to-bottom, mirroring a list filling in. `region` (table coordinate
    /// space) confines the wipe to a sub-rect — pass `DotMatrixRegion.changedRegion(...)`
    /// so only the rows that actually appear/disappear/move pixelate; nil wipes the whole
    /// visible table.
    public static func update(_ table: UITableView,
                              direction: DotMatrixWavefrontDirection = .topToBottom,
                              region: CGRect? = nil,
                              _ updates: () -> Void,
                              completion: ((Bool) -> Void)? = nil) {
        // The sub-rect to wipe (and snapshot), in the table's own coords, clamped to its
        // visible bounds. A region that collapses to nothing ⇒ nothing to animate.
        let visible = table.bounds
        let rect = (region ?? visible).intersection(visible)

        guard DotMatrixTransitionCenter.shared.isEnabled,
              let host = table.superview,
              rect.width > 1, rect.height > 1,
              let before = DotMatrixSnapshot.image(of: table, region: rect, afterScreenUpdates: false) else {
            table.performBatchUpdates(updates, completion: completion)
            return
        }

        UIView.performWithoutAnimation {
            table.performBatchUpdates(updates, completion: nil)
        }
        table.layoutIfNeeded()

        guard let after = DotMatrixSnapshot.image(of: table, region: rect, afterScreenUpdates: true),
              let overlay = DotMatrixTransitionCenter.shared.borrowOverlay(for: table.window) else {
            completion?(true); return
        }

        overlay.style = DotMatrixTransitionStyleProvider.style(for: table.traitCollection)
        overlay.direction = direction
        // Position the overlay over the changed sub-rect, converted into HOST coordinates
        // (the overlay is a sibling of the table). For a full-bounds wipe this reduces to
        // `table.frame`, matching the original behaviour.
        overlay.frame = host.convert(rect, from: table)
        overlay.autoresizingMask = []
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
