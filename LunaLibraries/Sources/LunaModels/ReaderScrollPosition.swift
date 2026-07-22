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
}
