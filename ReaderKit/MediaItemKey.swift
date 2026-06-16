//
//  MediaItemKey.swift
//  Clip
//

import Foundation

/// Synthetic canonical key for URL-less music/podcast items (so the store, which
/// keys on `urlString`, and local routing work). Shape:
/// `clickmusic://item?artist=…&title=…` / `clickpodcast://item?show=…&title=…`.
/// Not a shareable http URL — these share via the CloudKit `mediaItem` case.
enum MediaItemKey {
    static func url(platform: ContentPlatform, creator: String, title: String) -> String {
        let scheme = platform == .podcast ? "clickpodcast" : "clickmusic"
        let creatorKey = platform == .podcast ? "show" : "artist"
        var components = URLComponents()
        components.scheme = scheme
        components.host = "item"
        components.queryItems = [
            URLQueryItem(name: creatorKey, value: creator),
            URLQueryItem(name: "title", value: title),
        ]
        return components.url?.absoluteString ?? "\(scheme)://item"
    }
}
