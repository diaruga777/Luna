//
//  TypewriterScroller.swift
//  LunaWriterEditor
//

import UIKit

/// Keeps the caret line at a fixed height on the screen.
///
/// Pure geometry over a caret rectangle and the visible box, so the editor and
/// a test agree on where the line lands.
public enum TypewriterScroller {

    /// The vertical content offset that puts `caret` at `fraction` of the
    /// visible height. Never scrolls above the top of the document.
    public static func verticalOffset(
        caret: CGRect, visibleHeight: CGFloat, topInset: CGFloat,
        contentHeight: CGFloat, bottomInset: CGFloat,
        fraction: CGFloat = EditorMetrics.typewriterFraction
    ) -> CGFloat {
        let line = (visibleHeight - topInset) * fraction
        let wanted = caret.midY - line - topInset
        let lowest = max(-topInset, contentHeight + bottomInset - visibleHeight)
        return min(max(-topInset, wanted), lowest)
    }

    /// The extra room under the last line, so it too can sit at the
    /// typewriter position instead of the bottom of the screen.
    public static func bottomInset(
        visibleHeight: CGFloat, fraction: CGFloat = EditorMetrics.typewriterFraction
    ) -> CGFloat {
        max(0, visibleHeight * (1 - fraction))
    }

    /// How long the scroll takes. Short enough to feel like the page moving
    /// under the caret rather than an animation.
    public static let duration: TimeInterval = 0.15
}
