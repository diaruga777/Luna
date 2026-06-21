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
    /// Any recognized non-YouTube platform (X, Bluesky, Reddit, music, …).
    case platform(ContentPlatform, itemID: String?)

    /// Classifies a URL via the shared `PlatformRecognizer`, or nil when it's a
    /// readable article/document.
    static func detect(urlString: String) -> NonTextualContent? {
        guard let recognized = PlatformRecognizer.recognize(urlString) else { return nil }
        if recognized.platform == .youtube, let videoID = recognized.itemID {
            return .youTube(videoID: videoID)
        }
        return .platform(recognized.platform, itemID: recognized.itemID)
    }

    /// The classified platform.
    var platform: ContentPlatform {
        switch self {
        case .youTube: return .youtube
        case .platform(let platform, _): return platform
        }
    }

    /// A short human label for the kind of content.
    var kindLabel: String { platform.displayName }

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
        case .platform:
            return nil // non-YouTube platforms aren't embedded in the extension
        }
    }

    /// Referer required by the embed (YouTube rejects embeds without one, error 153).
    var embedReferer: String { "https://clip-reader.app/" }

    /// A static poster image for the content, when one is cheaply derivable from the
    /// URL alone (YouTube's thumbnail). Used to preview without spinning up a player.
    var staticPreviewImageURL: URL? {
        switch self {
        case .youTube(let videoID):
            return URL(string: "https://img.youtube.com/vi/\(videoID)/hqdefault.jpg")
        case .platform:
            return nil
        }
    }
}
