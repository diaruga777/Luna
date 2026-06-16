//
//  SaveMediaItemIntents.swift
//  Clip
//

import AppIntents
import Foundation

/// Saves a URL-less music item (artist + track) — the now-playing capture path
/// for Spotify / Apple Music. Cover art + provider links resolve at render time
/// from the preferred provider.
struct SaveMusicItemIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Song"
    static let description = IntentDescription(
        "Saves a song by artist + title to your Click reading list (no link needed).")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Artist") var artist: String
    @Parameter(title: "Title") var title: String

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: .music,
            creator: artist.trimmingCharacters(in: .whitespacesAndNewlines),
            title: title.trimmingCharacters(in: .whitespacesAndNewlines))
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
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: .podcast,
            creator: show.trimmingCharacters(in: .whitespacesAndNewlines),
            title: episode.trimmingCharacters(in: .whitespacesAndNewlines))
        return .result(value: item.urlString)
    }
}
