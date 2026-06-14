//
//  YouTubeSettings.swift
//  Clip
//

import Foundation

/// YouTube integration preferences (the OAuth tokens live in the Keychain via
/// `GoogleAuthClient`; these are plain settings).
enum YouTubeSettings {
    private static let playlistIDKey = "youtubePlaylistID"
    private static let playlistTitleKey = "youtubePlaylistTitle"
    private static let autoAddKey = "youtubeAutoAddToPlaylist"

    /// Clip's Google Cloud OAuth iOS client ID (shipped with the app — users
    /// don't provide their own).
    static let googleClientID =
        "651383166044-9galm8odrsc0l2ndanjgrthf0q1sdmf2.apps.googleusercontent.com"

    /// Target playlist for "add to watch later" (the real Watch Later playlist
    /// is closed to the API, so the user picks/creates one).
    static var playlistID: String? {
        get { UserDefaults.standard.string(forKey: playlistIDKey) }
        set { UserDefaults.standard.set(newValue, forKey: playlistIDKey) }
    }

    static var playlistTitle: String? {
        get { UserDefaults.standard.string(forKey: playlistTitleKey) }
        set { UserDefaults.standard.set(newValue, forKey: playlistTitleKey) }
    }

    /// Automatically add every newly saved video to the playlist and mark it read.
    static var autoAddToPlaylist: Bool {
        get { UserDefaults.standard.bool(forKey: autoAddKey) }
        set { UserDefaults.standard.set(newValue, forKey: autoAddKey) }
    }
}
