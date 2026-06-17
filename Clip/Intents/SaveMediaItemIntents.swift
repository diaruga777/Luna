//
//  SaveMediaItemIntents.swift
//  Clip
//

import AppIntents
import Foundation

/// Saves a URL-less music item (artist + track) — the now-playing capture path
/// for streaming-music apps. Cover art + provider links resolve at render time
/// from the preferred provider.
struct SaveMusicItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Song"
    static let description = IntentDescription(
        "Saves a song by artist + title to your Click reading list (no link needed).")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Artist") var artist: String
    @Parameter(title: "Title") var title: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cleanArtist = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: .music, creator: cleanArtist, title: cleanTitle)
        if let art = await MediaArtFetcher.fetchArtwork(
            creator: cleanArtist, title: cleanTitle, isPodcast: false) {
            ReadingListStore.shared.setThumbnail(art, for: item.id)
        }
        return .result(value: item.urlString)
    }
}

/// Saves a URL-less podcast item (show + episode).
struct SavePodcastItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Podcast"
    static let description = IntentDescription(
        "Saves a podcast episode by show + episode to your Click reading list (no link needed).")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Show") var show: String
    @Parameter(title: "Episode") var episode: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cleanShow = show.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanEpisode = episode.trimmingCharacters(in: .whitespacesAndNewlines)
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: .podcast, creator: cleanShow, title: cleanEpisode)
        if let art = await MediaArtFetcher.fetchArtwork(
            creator: cleanShow, title: cleanEpisode, isPodcast: true) {
            ReadingListStore.shared.setThumbnail(art, for: item.id)
        }
        return .result(value: item.urlString)
    }
}
