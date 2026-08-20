//
//  ArchiveTrayPullPolicy.swift
//  Luna
//

import UIKit

/// The rule deciding whether the archive arc's pan may START a pull, kept
/// apart from the gesture recognizer so it can be exercised without
/// synthesizing a `UIPanGestureRecognizer`'s velocity.
enum ArchiveTrayPullPolicy {

    static func shouldBeginPull(
        progress: CGFloat,
        chromeHidden: Bool,
        hasContent: Bool,
        canPull: Bool,
        cardClaimsDrag: Bool,
        velocity: CGPoint
    ) -> Bool {
        // An invisible (chrome-hidden) arc must not be pullable.
        guard !chromeHidden else { return false }
        guard abs(velocity.x) > abs(velocity.y) else { return false }
        // An arc that is already out can always finish its interaction — that
        // includes closing it again — whatever the checks below would say.
        guard progress <= 0 else { return true }
        // A playable card owns horizontal drags for paging or its playback
        // control, so the arc must not open under that same finger.
        guard !cardClaimsDrag else { return false }
        // Nothing to reveal — never start a pull for an empty arc (there is no
        // empty state to show) or away from the edge card it belongs to.
        guard hasContent, canPull else { return false }
        return velocity.x < 0
    }
}
