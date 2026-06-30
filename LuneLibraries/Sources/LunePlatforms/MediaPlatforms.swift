//
//  MediaPlatforms.swift
//  Lune
//

import LuneFetch
import LuneHTMLClassification
import LuneModels
import Foundation

/// Music links (Spotify track/album/artist, Apple Music). Provider-portable: the
/// reading list opens these in the user's preferred app (`openMediaItem`), so
/// `appDeepLink`/`embed` here are nil — routing is handled specially.
public struct MusicPlatform: PlatformModule {
    public let platform: ContentPlatform = .music
    public let glyphSymbolName = "music.note"

    public func subtitle(for item: ReadingListItem) -> String? { item.mediaCreatorName ?? item.channelName }
    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }
    public var metadataFetcher: PlatformMetadataFetching? { MediaMetadataFetcher() }
}

/// Podcast links (Spotify episode/show, Apple Podcasts). Same provider-portable
/// handling as music.
public struct PodcastPlatform: PlatformModule {
    public let platform: ContentPlatform = .podcast
    public let glyphSymbolName = "mic.fill"

    public func subtitle(for item: ReadingListItem) -> String? { item.mediaCreatorName ?? item.channelName }
    public func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    public func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }
    public var metadataFetcher: PlatformMetadataFetching? { MediaMetadataFetcher() }
}

/// Best-effort cover art + artist/track: iTunes Lookup (Apple, keyless) or
/// Spotify oEmbed (keyless).
public struct MediaMetadataFetcher: PlatformMetadataFetching {
    public func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        switch (match.platform, match.sourceService) {
        // Podcast episodes aren't lookup-able by their episode id, so scrape the
        // page (og:title episode + og:image art) and look up the show for its name.
        case (.podcast, .apple): return await applePodcastMetadata(urlString: urlString)
        case (_, .apple): return await appleLookup(itemID: match.itemID)
        case (_, .spotify): return await spotifyOEmbed(urlString: urlString)
        default: return nil
        }
    }

    private func applePodcastMetadata(urlString: String) async -> PlatformMetadata? {
        guard let url = URL(string: urlString) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 12)
        request.setValue(ArticleFetcher.safariUserAgent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let html = String(data: data, encoding: .utf8)
        else { return nil }

        let episodeTitle = LeadImageExtractor.metaContent(property: "og:title", in: html)
        var thumbnailData: Data?
        if let artURL = LeadImageExtractor.imageURL(in: html, baseURL: url) {
            thumbnailData = try? await URLSession.shared.data(from: artURL).0
        }
        // The show id in the path (id1234567890) IS lookup-able — gives the show name.
        var showName: String?
        if let showID = Self.applePodcastShowID(in: url),
           let lookupURL = URL(string: "https://itunes.apple.com/lookup?id=\(showID)"),
           let (lookupData, lookupResponse) = try? await URLSession.shared.data(from: lookupURL),
           let lookupHTTP = lookupResponse as? HTTPURLResponse,
           (200..<300).contains(lookupHTTP.statusCode),
           let decoded = try? JSONDecoder().decode(ITunesResult.self, from: lookupData) {
            showName = decoded.results.first?.collectionName
        }

        guard episodeTitle != nil || showName != nil || thumbnailData != nil else { return nil }
        return PlatformMetadata(
            title: episodeTitle ?? showName, creator: showName, thumbnailData: thumbnailData,
            mediaCreatorName: showName, mediaItemTitle: episodeTitle)
    }

    private static func applePodcastShowID(in url: URL) -> String? {
        for segment in url.pathComponents where segment.hasPrefix("id") {
            let digits = String(segment.dropFirst(2))
            if !digits.isEmpty, digits.allSatisfy(\.isNumber) { return digits }
        }
        return nil
    }

    private struct ITunesResult: Decodable {
        let results: [Entry]
        struct Entry: Decodable {
            let trackName: String?
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
    }

    private func appleLookup(itemID: String?) async -> PlatformMetadata? {
        // Music track/album ids ARE lookup-able (unlike podcast episode ids). Path
        // ids may carry an "id" prefix; the lookup wants the bare number.
        guard let itemID else { return nil }
        let numericID = itemID.hasPrefix("id") ? String(itemID.dropFirst(2)) : itemID
        guard let url = URL(string: "https://itunes.apple.com/lookup?id=\(numericID)"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let decoded = try? JSONDecoder().decode(ITunesResult.self, from: data),
              let entry = decoded.results.first
        else { return nil }

        var thumbnailData: Data?
        if let art = entry.artworkUrl100,
           let artURL = URL(string: art.replacingOccurrences(of: "100x100", with: "300x300")) {
            thumbnailData = try? await URLSession.shared.data(from: artURL).0
        }
        let title = entry.trackName ?? entry.collectionName
        return PlatformMetadata(
            title: title, creator: entry.artistName, thumbnailData: thumbnailData,
            mediaCreatorName: entry.artistName, mediaItemTitle: title)
    }

    private struct SpotifyOEmbed: Decodable {
        let title: String?
        let thumbnail_url: String?
    }

    private func spotifyOEmbed(urlString: String) async -> PlatformMetadata? {
        guard var components = URLComponents(string: "https://open.spotify.com/oembed") else { return nil }
        components.queryItems = [URLQueryItem(name: "url", value: urlString)]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let oembed = try? JSONDecoder().decode(SpotifyOEmbed.self, from: data)
        else { return nil }

        var thumbnailData: Data?
        if let thumb = oembed.thumbnail_url, let thumbURL = URL(string: thumb) {
            thumbnailData = try? await URLSession.shared.data(from: thumbURL).0
        }
        // Spotify oEmbed gives a combined title (e.g. "Song"); artist isn't split.
        return PlatformMetadata(
            title: oembed.title, thumbnailData: thumbnailData, mediaItemTitle: oembed.title)
    }
}
