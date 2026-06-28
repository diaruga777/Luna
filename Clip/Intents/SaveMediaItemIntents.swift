//
//  SaveMediaItemIntents.swift
//  Clip
//

import ClipIntents
import ClipPlatforms
import ClipStorage
import AppIntents
import Foundation

/// Saves a URL-less music item (artist + track) — the now-playing capture path
/// for streaming-music apps. Cover art + provider links resolve at render time
/// from the preferred provider.
public struct SaveMusicItemIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Song"
    public static let description = IntentDescription(
        "Saves a song by artist + title to your Queue reading list (no link needed).")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Artist", description: "The artist name (text).") var artist: String
    @Parameter(title: "Title", description: "The song / track title (text).") var title: String

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
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
public struct SavePodcastItemIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Podcast Episode"
    public static let description = IntentDescription(
        "Saves a podcast episode by show name + episode title (text) to your Queue reading list (no link needed).")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Show", description: "The podcast show's name (text).") var show: String
    @Parameter(
        title: "Episode Title",
        description: "The episode's title as TEXT — not an episode number.")
    public var episode: String

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
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
