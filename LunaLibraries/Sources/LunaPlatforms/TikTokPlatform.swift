//
//  TikTokPlatform.swift
//  Luna
//

import LunaModels
import Foundation

/// Recognizes TikTok links: `tiktok.com/@<user>/video/<id>` and short
/// `vm.tiktok.com/<code>` / `vt.tiktok.com/<code>` (kept opaque — id unknown
/// until resolved). Pure.
public enum TikTokLink {
    public static func isTikTok(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString)?.host?.lowercased() else { return false }
        return host == "tiktok.com" || host.hasSuffix(".tiktok.com")
    }

    /// The numeric video id from a full `/@user/video/<id>` URL, if present.
    public static func videoID(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isTikTok(urlString) else { return nil }
        let segments = Array(url.pathComponents.dropFirst())
        guard let videoIndex = segments.firstIndex(of: "video"), videoIndex + 1 < segments.count else {
            return nil
        }
        let id = segments[videoIndex + 1]
        return id.allSatisfy(\.isNumber) && !id.isEmpty ? id : nil
    }

    /// The creator handle ("@user") from `/@user/video/<id>`, if present.
    public static func handle(from urlString: String) -> String? {
        guard let url = URL(string: urlString), isTikTok(urlString) else { return nil }
        return url.pathComponents.dropFirst().first { $0.hasPrefix("@") && $0.count > 1 }
    }
}

/// TikTok videos. Opens in Safari (no reliable per-video app scheme); oEmbed
/// supplies author/title/thumbnail.
public struct TikTokPlatform: PlatformModule {
    public let platform: ContentPlatform = .tiktok
    public let glyphSymbolName = "music.note"

    public func subtitle(for item: ReadingListItem) -> String? {
        item.channelName ?? TikTokLink.handle(from: item.urlString)
    }
    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }

    public var metadataFetcher: PlatformMetadataFetching? { TikTokMetadataFetcher() }
}

/// Keyless TikTok oEmbed: author, title, thumbnail.
public struct TikTokMetadataFetcher: PlatformMetadataFetching {
    private struct OEmbed: Decodable {
        let title: String?
        let author_name: String?
        let thumbnail_url: String?
    }

    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        guard var components = URLComponents(string: "https://www.tiktok.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let oembed = try? JSONDecoder().decode(OEmbed.self, from: data)
        else { return nil }

        var thumbnailData: Data?
        if let thumb = oembed.thumbnail_url, let thumbURL = URL(string: thumb) {
            thumbnailData = try? await URLSession.shared.data(from: thumbURL).0
        }
        return PlatformMetadata(
            title: oembed.title, creator: oembed.author_name, thumbnailData: thumbnailData)
    }
}
