//
//  ReaderScrollPosition.swift
//  LunaModels
//


import Foundation

/// Shared persistence rules for scroll-based reader modes.
public enum ReaderScrollPosition {
    /// A position within the card's title region is treated as the top. Restoring
    /// a sliver of that region is visually worse than restoring its complete title.
    public static func normalizedForPersistence(
        _ offset: Double, titleHeaderHeight: Double
    ) -> Double {
        offset <= max(0, titleHeaderHeight) ? 0 : offset
    }

    /// Converts the canonical persisted top (`0`) back to UIKit's raw content
    /// offset. A scroll view with a top inset rests at `-adjustedTopInset`, not at
    /// raw zero; restoring raw zero would immediately hide the in-inset title.
    /// Nonzero persisted offsets retain their existing pixel-exact semantics.
    public static func contentOffsetForRestoration(
        _ persistedOffset: Double, adjustedTopInset: Double
    ) -> Double {
        persistedOffset == 0 ? -max(0, adjustedTopInset) : persistedOffset
    }

    /// Which of a card's two identical title copies owns the title — the copy
    /// pinned to the card, or the one riding the scroll view's top inset.
    ///
    /// The decision is LATCHED between two thresholds instead of flipping on one
    /// shared edge. The pinned copy takes over only once the scrolling copy has
    /// left the card entirely, and hands back exactly when the scrolling copy is
    /// home again — where the two are pixel-identical, so the swap renders no
    /// changed pixels. Between the thresholds the previous owner keeps it: with
    /// a single edge, scrolling back to the top dropped the pinned copy while
    /// the scrolling copy was still fully above the card, so the title blinked
    /// out and then slid back in.
    public static func pinnedTitleOwnsTitle(
        wasPinned: Bool, distanceFromTop: Double, titleHeaderHeight: Double
    ) -> Bool {
        if distanceFromTop > max(0, titleHeaderHeight) + 1 { return true }
        if distanceFromTop <= 0.5 { return false }
        return wasPinned
    }
}
