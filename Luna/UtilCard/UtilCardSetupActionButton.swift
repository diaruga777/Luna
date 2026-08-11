//
//  UtilCardSetupActionButton.swift
//  Luna
//

import UIKit

/// A setup-block button whose TITLE slides sideways in place — central Luna
/// cycles its Safari and shortcut phrasing while the weekly row turns
/// (`UtilCardSetupTextCycler`).
///
/// The subclass exists for one reason: UIKit positions a configuration button's
/// title by ASSIGNING ITS FRAME, and assigning a frame to a view that carries a
/// transform makes UIKit solve for the centre that puts the *transformed* view
/// at that frame. So every layout pass that landed mid-slide — the cycler's own
/// `layoutIfNeeded` after the swap, or any card reflow that happened to fall
/// inside those 0.55s — baked the slide's offset into the label's centre, and
/// the title walked toward the trailing edge one cycle at a time until it read
/// as right-aligned. The transform is therefore lifted off for the duration of
/// the layout and put back after, so UIKit always lays the label out at rest
/// and the slide stays a pure overlay on top of that. (`WeeklySaveRowHost`
/// solves the same conflict the other way, by skipping rows it is animating —
/// an option only open to a view that owns the frames itself.)
final class UtilCardSetupActionButton: UIButton {
    override func layoutSubviews() {
        guard let label = titleLabel, !label.transform.isIdentity else {
            super.layoutSubviews()
            return
        }
        let slide = label.transform
        label.transform = .identity
        super.layoutSubviews()
        label.transform = slide
    }
}
