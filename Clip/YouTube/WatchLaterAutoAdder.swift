//
//  WatchLaterAutoAdder.swift
//  Clip
//

import Foundation
import os

/// Adds newly ingested videos to the user's chosen playlist and marks them
/// read, when the auto-add setting is on. Runs only from first-time video
/// ingestion — repeat save presses never reach it.
final class WatchLaterAutoAdder {

    static let shared = WatchLaterAutoAdder()

    private let logger = Logger(subsystem: "com.hpiddy.clip", category: "youtube")
    private let auth: GoogleAuthProviding
    private let api: YouTubeAPIProviding
    private let store: ReadingListStore

    init(auth: GoogleAuthProviding = GoogleAuthClient.shared,
         api: YouTubeAPIProviding? = nil,
         store: ReadingListStore = .shared) {
        self.auth = auth
        self.api = api ?? YouTubeAPIClient(auth: auth)
        self.store = store
    }

    func videoBecameReady(_ item: ReadingListItem) async {
        guard YouTubeSettings.autoAddToPlaylist,
              let playlistID = YouTubeSettings.playlistID,
              auth.isSignedIn,
              let videoID = item.youtubeVideoID
        else { return }
        do {
            try await api.addToPlaylist(playlistID: playlistID, videoID: videoID)
            store.markReadState(.read, for: item.id)
            logger.info("auto-added \(videoID, privacy: .public) to playlist")
        } catch {
            logger.error("auto-add failed: \(String(describing: error), privacy: .public)")
        }
    }
}
