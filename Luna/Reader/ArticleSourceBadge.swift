//
//  ArticleSourceBadge.swift
//  Luna
//
//  Maps a reading-list item to the instant fallback badge for its mini-card
//  scrub chip — before (or instead of) a fetched favicon: email imports get
//  the sender's initials (or a mail glyph when the sender is unknown),
//  documents a document glyph, and web saves a globe until their site icon
//  arrives. Pure so the mapping is unit-testable.
//

import LunaDesignSystem
import LunaModels

enum ArticleSourceBadge {

    static func fallback(for item: ReadingListItem) -> CarouselSourceBadge {
        if item.effectiveCaptureSource == .email || item.url?.scheme == "lunamail" {
            if let sender = item.channelName,
               !CarouselSourceBadge.initials(fromName: sender).isEmpty {
                return .sender(sender)
            }
            return .symbol("envelope.fill")
        }
        if item.isDocument {
            return .symbol("doc.text.fill")
        }
        return .symbol("globe")
    }

    /// Whether the item's site icon is worth fetching (a real web URL).
    static func wantsFavicon(_ item: ReadingListItem) -> Bool {
        ReadingListItem.isWebPageURL(item.urlString)
    }
}
