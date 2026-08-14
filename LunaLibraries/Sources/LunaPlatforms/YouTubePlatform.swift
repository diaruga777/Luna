//
//  YouTubePlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// YouTube videos and Shorts. oEmbed returns the real video title without an
/// API key; a video ID also gives us a stable thumbnail URL when oEmbed cannot.
public struct YouTubePlatform: PlatformModule {
    public let platform: ContentPlatform = .youtube
    public let glyphSymbolName = "play.rectangle.fill"

    public func appDeepLink(for item: SavedItem) -> URL? { nil }
    public func embed(for item: SavedItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { YouTubeMetadataFetcher() }
}

public struct YouTubeMetadataFetcher: PlatformMetadataFetching {
    private struct OEmbed: Decodable {
        let title: String?
        let thumbnail_url: String?
    }

    public init() {}

    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        let videoID = match.itemID ?? Self.videoID(from: urlString)
        guard let metadataURL = Self.oEmbedURL(videoID: videoID) else { return nil }

        var request = URLRequest(url: metadataURL, timeoutInterval: 12)
        request.setValue("Luna/1.0", forHTTPHeaderField: "User-Agent")
        let oembed: OEmbed?
        if let (data, response) = try? await URLSession.shared.data(for: request),
           let response = response as? HTTPURLResponse,
           (200..<300).contains(response.statusCode) {
            oembed = try? JSONDecoder().decode(OEmbed.self, from: data)
        } else {
            oembed = nil
        }

        let fallbackThumbnailURL = Self.thumbnailURL(videoID: videoID)
        let oEmbedThumbnailURL = oembed?.thumbnail_url.flatMap(URL.init(string:))
        var thumbnailData = await Self.imageData(at: oEmbedThumbnailURL ?? fallbackThumbnailURL)
        if thumbnailData == nil, oEmbedThumbnailURL != fallbackThumbnailURL {
            thumbnailData = await Self.imageData(at: fallbackThumbnailURL)
        }
        guard oembed?.title != nil || thumbnailData != nil else { return nil }
        return PlatformMetadata(title: oembed?.title, thumbnailData: thumbnailData)
    }

    static func oEmbedURL(videoID: String?) -> URL? {
        guard let videoID = validVideoID(videoID) else { return nil }
        var components = URLComponents(string: "https://www.youtube.com/oembed")
        components?.queryItems = [
            URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(videoID)"),
            URLQueryItem(name: "format", value: "json"),
        ]
        return components?.url
    }

    static func thumbnailURL(videoID: String?) -> URL? {
        guard let videoID = validVideoID(videoID) else { return nil }
        return URL(string: "https://i.ytimg.com/vi/\(videoID)/hqdefault.jpg")
    }

    private static func videoID(from urlString: String) -> String? {
        guard let components = URLComponents(string: urlString) else { return nil }
        let path = components.path.split(separator: "/")
        if components.host?.lowercased() == "youtu.be" { return path.first.map(String.init) }
        if let queryID = components.queryItems?.first(where: { $0.name == "v" })?.value { return queryID }
        guard path.count > 1, ["shorts", "live", "embed", "v"].contains(String(path[0])) else {
            return nil
        }
        return String(path[1])
    }

    private static func validVideoID(_ candidate: String?) -> String? {
        guard let candidate, candidate.count == 11,
              candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" })
        else { return nil }
        return candidate
    }

    private static func imageData(at url: URL?) async -> Data? {
        guard let url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let response = response as? HTTPURLResponse,
              (200..<300).contains(response.statusCode)
        else { return nil }
        return data
    }
}
