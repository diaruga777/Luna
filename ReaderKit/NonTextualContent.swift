//
//  NonTextualContent.swift
//  Clip
//

import Foundation

/// A saved URL whose primary content isn't readable article text — a video
/// today, more platforms later. These are handled by playing/embedding the
/// content rather than running the text extractor (which would fail or produce
/// junk). Lives in ReaderKit so both the app and the extensions can classify a
/// URL the same way.
enum NonTextualContent: Equatable {
    case youTube(videoID: String)

    /// Classifies a URL, or nil when it's (probably) a readable article/document.
    /// Add new platforms here as they're supported.
    static func detect(urlString: String) -> NonTextualContent? {
        if let videoID = YouTubeURL.videoID(from: urlString) {
            return .youTube(videoID: videoID)
        }
        return nil
    }

    /// A short human label for the kind of content.
    var kindLabel: String {
        switch self {
        case .youTube: return "Video"
        }
    }

    /// The page to load in a webview for in-app playback. For YouTube this is
    /// the `/embed/` URL loaded directly — `loadHTMLString` origins and
    /// youtube.com referers are rejected with errors 152/153, so the embed page
    /// must be loaded as a real request (with a non-empty Referer; see
    /// `embedReferer`).
    var embedURL: URL? {
        switch self {
        case .youTube(let videoID):
            var components = URLComponents(string: "https://www.youtube.com/embed/\(videoID)")
            components?.queryItems = [
                URLQueryItem(name: "playsinline", value: "1"),
                URLQueryItem(name: "autoplay", value: "1"),
                URLQueryItem(name: "rel", value: "0"),
            ]
            return components?.url
        }
    }

    /// Referer required by the embed (YouTube rejects embeds without one, error 153).
    var embedReferer: String { "https://clip-reader.app/" }
}
