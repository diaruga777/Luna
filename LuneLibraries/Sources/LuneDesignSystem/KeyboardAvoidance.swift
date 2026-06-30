//
//  KeyboardAvoidance.swift
//  Lune
//

import UIKit

/// Pure geometry helpers for keyboard-avoidance, factored out so the math is
/// unit-testable without a live keyboard or window.
public enum KeyboardAvoidance {

    /// The bottom content inset a scroll view needs so its content clears the
    /// keyboard. `keyboardFrameInView` is the keyboard's frame converted into the
    /// scroll view's coordinate space; `scrollViewBounds` is the scroll view's own
    /// bounds. Returns the overlap between the keyboard and the scroll view (0 when
    /// the keyboard is fully below the scroll view, e.g. on dismissal).
    public static func bottomInset(
        keyboardFrameInView keyboardFrame: CGRect,
        scrollViewBounds: CGRect
    ) -> CGFloat {
        let overlap = scrollViewBounds.maxY - keyboardFrame.minY
        return max(0, overlap)
    }

    /// The vertical content offset that brings `targetFrame` (in content
    /// coordinates) fully into the still-visible region of the scroll view once the
    /// keyboard is up, leaving `padding` of breathing room below the field. Returns
    /// `nil` when the field is already fully visible (no scroll needed).
    ///
    /// `visibleHeight` is the scroll view's height minus the keyboard overlap (the
    /// region not covered by the keyboard). The result is clamped to the legal
    /// offset range `[0, maxContentOffsetY]`.
    public static func contentOffsetToReveal(
        targetFrame: CGRect,
        currentOffsetY: CGFloat,
        visibleHeight: CGFloat,
        maxContentOffsetY: CGFloat,
        padding: CGFloat
    ) -> CGFloat? {
        let visibleTop = currentOffsetY
        let visibleBottom = currentOffsetY + visibleHeight

        let desiredOffsetY: CGFloat
        if targetFrame.maxY + padding > visibleBottom {
            // Field bottom is hidden behind (or near) the keyboard — scroll up.
            desiredOffsetY = targetFrame.maxY + padding - visibleHeight
        } else if targetFrame.minY < visibleTop {
            // Field top is above the visible region — scroll down to it.
            desiredOffsetY = targetFrame.minY
        } else {
            return nil
        }

        let clamped = min(max(0, desiredOffsetY), max(0, maxContentOffsetY))
        return clamped == currentOffsetY ? nil : clamped
    }
}
