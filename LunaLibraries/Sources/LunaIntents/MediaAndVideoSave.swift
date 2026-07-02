//
//  MediaAndVideoSave.swift
//  LunaIntents
//
//  Shared bodies for the intents that save URL-less media items and looked-up
//  YouTube videos — the Save/Find intent pairs and SaveFromAppIntent's app
//  ladders all funnel through here so they can't drift.
//

import LunaModels
import LunaPlatforms
import LunaStorage
import LunaURLClassification
import LunaYouTubeAPI
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

public enum YouTubeVideoSave {
    /// Why a lookup couldn't produce a save — each intent maps these to its own
    /// user-facing error strings.
    public enum FindFailure: Error {
        case notSignedIn, badQuery, channelNotFound, videoNotFound
    }

    /// Finds a video by channel name + title via the YouTube Data API (lenient
    /// matching) and saves it. Returns the saved watch URL string.
    @discardableResult
    public static func findAndSave(channel: String, title: String) async throws -> String {
        guard await GoogleAuthClient.shared.isSignedIn else { throw FindFailure.notSignedIn }
        let channelName = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelName.isEmpty, !videoTitle.isEmpty else { throw FindFailure.badQuery }
        let api = YouTubeAPIClient()
        guard let channelID = try await api.searchChannelID(name: channelName) else {
            throw FindFailure.channelNotFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: videoTitle)
        guard let match = VideoMatchSelection.bestMatch(title: videoTitle, candidates: candidates)
        else { throw FindFailure.videoNotFound }
        let urlString = YouTubeURL.watchURLString(videoID: match.videoID)
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString)
        return urlString
    }
}
