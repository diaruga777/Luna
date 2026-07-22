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
}
