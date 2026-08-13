//
//  XPlatform.swift
//  Luna
//

import LunaModels
import LunaURLClassification
import Foundation

/// Recognizes X / Twitter status links: `(x|twitter).com/<user>/status/<id>`
/// (id is the 19-ish-digit tweet id). Pure.
public enum XLink {
    /// The tweet id from a status URL. Host recognition delegates to
    /// `PlatformRecognizer` (any x.com/twitter.com subdomain); this only owns the
    /// status-segment parsing.
    public static func tweetID(from urlString: String) -> String? {
        guard PlatformRecognizer.recognize(urlString)?.platform == .x,
              let url = URL(string: urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let statusIndex = segments.firstIndex(where: { $0 == "status" || $0 == "statuses" }),
              statusIndex + 1 < segments.count else { return nil }
        let id = segments[statusIndex + 1]
        guard id.allSatisfy(\.isNumber), !id.isEmpty else { return nil }
        return id
    }

    public static func appURL(tweetID: String) -> URL? { URL(string: "twitter://status?id=\(tweetID)") }
}

/// X posts. Opens the X/Twitter app via `twitter://status?id=`, else Safari
/// (the timeline isn't a clean embed). Metadata via the keyless fxtwitter API.
public struct XPlatform: PlatformModule {
    public let platform: ContentPlatform = .x
    public let glyphSymbolName = "bird.fill"

    public func appDeepLink(for item: SavedItem) -> URL? {
        (item.platformItemID).flatMap(XLink.appURL(tweetID:))
    }

    public func embed(for item: SavedItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { XMetadataFetcher() }
}

/// Best-effort tweet metadata via fxtwitter (keyless JSON; simpler + more
/// reliable from a client than the syndication token endpoint).
public struct XMetadataFetcher: PlatformMetadataFetching {
    private struct Response: Decodable {
        let tweet: Tweet?
        struct Tweet: Decodable {
            let text: String?
            let author: Author?
            let media: Media?
            struct Author: Decodable { let name: String?; let screen_name: String? }
            struct Media: Decodable {
                let photos: [Photo]?
                let videos: [Video]?
                struct Photo: Decodable { let url: String? }
                struct Video: Decodable { let thumbnail_url: String? }
            }
        }
    }

    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard let id = match.itemID,
              let url = URL(string: "https://api.fxtwitter.com/status/\(id)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let tweet = decoded.tweet
        else { return nil }

        let title = tweet.text.map { String($0.prefix(140)) }

        // Attached photo or video still frame, if any.
        var thumbnailData: Data?
        let imageURLString = tweet.media?.photos?.first?.url
            ?? tweet.media?.videos?.first?.thumbnail_url
        if let imageURLString, let imageURL = URL(string: imageURLString) {
            thumbnailData = try? await URLSession.shared.data(from: imageURL).0
        }
        return PlatformMetadata(title: title, thumbnailData: thumbnailData)
    }
}
