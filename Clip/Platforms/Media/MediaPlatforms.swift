//
//  MediaPlatforms.swift
//  Clip
//

import Foundation

/// Music links (Spotify track/album/artist, Apple Music). Provider-portable: the
/// reading list opens these in the user's preferred app (`openMediaItem`), so
/// `appDeepLink`/`embed` here are nil — routing is handled specially.
struct MusicPlatform: PlatformModule {
    let platform: ContentPlatform = .music
    let glyphSymbolName = "music.note"

    func classify(_ urlString: String) -> PlatformMatch? {
        guard let match = MediaLink.classify(urlString), match.platform == .music else { return nil }
        return PlatformMatch(platform: .music, itemID: match.itemID, sourceService: match.service)
    }

    func subtitle(for item: ReadingListItem) -> String? { item.mediaCreatorName ?? item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }
    var metadataFetcher: PlatformMetadataFetching? { MediaMetadataFetcher() }
}

/// Podcast links (Spotify episode/show, Apple Podcasts). Same provider-portable
/// handling as music.
struct PodcastPlatform: PlatformModule {
    let platform: ContentPlatform = .podcast
    let glyphSymbolName = "mic.fill"

    func classify(_ urlString: String) -> PlatformMatch? {
        guard let match = MediaLink.classify(urlString), match.platform == .podcast else { return nil }
        return PlatformMatch(platform: .podcast, itemID: match.itemID, sourceService: match.service)
    }

    func subtitle(for item: ReadingListItem) -> String? { item.mediaCreatorName ?? item.channelName }
    func appDeepLink(for item: ReadingListItem) -> URL? { nil }
    func embed(for item: ReadingListItem) -> PlatformEmbed? { nil }
    var metadataFetcher: PlatformMetadataFetching? { MediaMetadataFetcher() }
}

/// Best-effort cover art + artist/track: iTunes Lookup (Apple, keyless) or
/// Spotify oEmbed (keyless).
struct MediaMetadataFetcher: PlatformMetadataFetching {
    func fetchMetadata(for match: PlatformMatch, urlString: String) async -> PlatformMetadata? {
        switch match.sourceService {
        case .apple: return await appleLookup(itemID: match.itemID, isPodcast: match.platform == .podcast)
        case .spotify: return await spotifyOEmbed(urlString: urlString)
        case .none: return nil
        }
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

    private func appleLookup(itemID: String?, isPodcast: Bool) async -> PlatformMetadata? {
        guard let itemID else { return nil }
        // Path ids carry an "id" prefix ("id1535970232"); the lookup wants the
        // bare number. Episode lookups require entity=podcastEpisode — without
        // it an episode id returns zero results.
        let numericID = itemID.hasPrefix("id") ? String(itemID.dropFirst(2)) : itemID
        guard var components = URLComponents(string: "https://itunes.apple.com/lookup") else { return nil }
        components.queryItems = [URLQueryItem(name: "id", value: numericID)]
        if isPodcast { components.queryItems?.append(URLQueryItem(name: "entity", value: "podcastEpisode")) }
        guard let url = components.url,
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
        // Podcasts: episode title + show name. Music: track title + artist.
        let title = entry.trackName ?? entry.collectionName
        let creator = isPodcast ? (entry.collectionName ?? entry.artistName) : entry.artistName
        return PlatformMetadata(
            title: title, creator: creator, thumbnailData: thumbnailData,
            mediaCreatorName: creator, mediaItemTitle: title)
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
