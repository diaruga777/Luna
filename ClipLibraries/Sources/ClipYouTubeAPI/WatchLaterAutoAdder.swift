//
//  WatchLaterAutoAdder.swift
//  Clip
//

import ClipModels
import Foundation
import os

/// Adds newly ingested videos to the user's chosen playlist when the auto-add
/// setting is on. Runs only from first-time video ingestion — repeat save presses
/// never reach it. Adding to a playlist does NOT mark the item read in our app:
/// saved inputs always stay unread on insert.
public final class WatchLaterAutoAdder {

    public static let shared = WatchLaterAutoAdder()

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "youtube")
    private let auth: GoogleAuthProviding
    private let api: YouTubeAPIProviding

    public init(auth: GoogleAuthProviding = GoogleAuthClient.shared,
         api: YouTubeAPIProviding? = nil) {
        self.auth = auth
        self.api = api ?? YouTubeAPIClient(auth: auth)
    }

    public func videoBecameReady(_ item: ReadingListItem) async {
        guard YouTubeSettings.autoAddToPlaylist,
              let playlistID = YouTubeSettings.playlistID,
              auth.isSignedIn,
              let videoID = item.youtubeVideoID
        else { return }
        do {
            try await api.addToPlaylist(playlistID: playlistID, videoID: videoID)
            logger.info("auto-added \(videoID, privacy: .public) to playlist")
        } catch {
            logger.error("auto-add failed: \(String(describing: error), privacy: .public)")
        }
    }
}
