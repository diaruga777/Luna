//
//  MediaAndVideoSave.swift
//  LunaIntents
//
//  Shared bodies for the intents that save URL-less media items.
//

import LunaModels
import LunaPlatforms
import LunaStorage
import LunaURLClassification
import Foundation

public enum MediaItemSave {
    /// Creates the URL-less media item (artist/show + title) and best-effort
    /// attaches cover art. Returns the created item.
    @discardableResult
    public static func save(
        platform: ContentPlatform, creator: String, title: String
    ) async -> ReadingListItem {
        let cleanCreator = creator.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: platform, creator: cleanCreator, title: cleanTitle)
        if let art = await MediaArtFetcher.fetchArtwork(
            creator: cleanCreator, title: cleanTitle, isPodcast: platform == .podcast) {
            ReadingListStore.shared.setThumbnail(art, for: item.id)
        }
        return item
    }
}
