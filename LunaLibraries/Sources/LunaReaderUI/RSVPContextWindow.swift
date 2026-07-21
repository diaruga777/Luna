//
//  RSVPContextWindow.swift
//  LunaReaderUI
//

import LunaReaderEngine

/// The ±N-word surrounding-prose context around whatever's currently on
/// screen, shared by the full reader's context labels (`updateContextText`)
/// and the link preview's (`updateContext`). The two use different radii (20
/// words vs 12) and the reader's Phrases mode excludes a whole phrase rather
/// than a single word, so both the radius and the excluded range stay
/// caller-supplied — only the "slice preceding/following text, clamped to the
/// word array's bounds" arithmetic is shared.
public enum RSVPContextWindow {
    public struct Context {
        public let preceding: String
        public let following: String
    }

    /// `shownRange` is the half-open word-index range currently on screen —
    /// excluded from the returned context — `index..<(index + 1)` for a
    /// single word, or (RSVP's Phrases mode) a phrase's `wordRange`. Returns
    /// nil when `shownRange` doesn't start within `words`.
    public static func context(
        around shownRange: Range<Int>, words: [RSVPWord], radius: Int
    ) -> Context? {
        guard words.indices.contains(shownRange.lowerBound) else { return nil }
        let precedingStart = max(0, shownRange.lowerBound - radius)
        let followingEnd = min(words.count, shownRange.upperBound + radius)
        return Context(
            preceding: words[precedingStart..<shownRange.lowerBound].map(\.text).joined(separator: " "),
            following: words[shownRange.upperBound..<followingEnd].map(\.text).joined(separator: " "))
    }
}
