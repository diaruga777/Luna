//
//  MediaLinks.swift
//  Clip
//

import Foundation

/// Parses Spotify / Apple Music / Apple Podcasts URLs into a provider-agnostic
/// `(platform, service, itemID)`, and converts a web URL to the matching app
/// scheme. Pure.
enum MediaLink {
    struct Match: Equatable {
        let platform: ContentPlatform // .music or .podcast
        let service: MusicProvider
        let itemID: String?
    }

    static func classify(_ urlString: String) -> Match? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        let queryID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "i" })?.value

        if host == "open.spotify.com" {
            guard let kind = segments.first else { return nil }
            let id = segments.count > 1 ? segments[1] : nil
            switch kind {
            case "track", "album", "artist": return Match(platform: .music, service: .spotify, itemID: id)
            case "episode", "show": return Match(platform: .podcast, service: .spotify, itemID: id)
            default: return nil
            }
        }
        if host == "music.apple.com" || host.hasSuffix(".music.apple.com") {
            return Match(platform: .music, service: .apple, itemID: queryID ?? segments.last)
        }
        if host == "podcasts.apple.com" || host.hasSuffix(".podcasts.apple.com") {
            return Match(platform: .podcast, service: .apple, itemID: queryID ?? segments.last)
        }
        return nil
    }

    /// Converts a web media URL to its app-scheme equivalent for exact opening.
    static func appSchemeURL(forWebURL urlString: String) -> URL? {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else { return nil }
        if host == "open.spotify.com" {
            // open.spotify.com/track/ID → spotify:track:ID
            let segments = url.pathComponents.dropFirst()
            guard !segments.isEmpty else { return nil }
            return URL(string: "spotify:" + segments.joined(separator: ":"))
        }
        if host.hasSuffix("music.apple.com") {
            return URL(string: urlString.replacingOccurrences(of: "https://", with: "music://"))
        }
        if host.hasSuffix("podcasts.apple.com") {
            return URL(string: urlString.replacingOccurrences(of: "https://", with: "podcasts://"))
        }
        return nil
    }
}

extension MusicProvider {
    /// App-scheme search deep link for "artist track" (provider-portable open).
    func appSearchURL(query: String) -> URL? {
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .apple: return URL(string: "music://music.apple.com/search?term=\(encoded)")
        case .spotify: return URL(string: "spotify:search:\(encoded)")
        }
    }

    /// Web search URL (Safari fallback when the app isn't installed).
    func webSearchURL(query: String) -> URL? {
        let queryEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        switch self {
        case .apple:
            return URL(string: "https://music.apple.com/search?term=\(queryEncoded)")
        case .spotify:
            let pathEncoded = query.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? query
            return URL(string: "https://open.spotify.com/search/\(pathEncoded)")
        }
    }
}
