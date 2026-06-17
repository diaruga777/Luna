//
//  SaveFromAppIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// One generic save action that adapts to the current app. Pass the current app
/// (from Get Current App) and the field(s) that app needs — the expected values
/// per app are documented below. Bridges the per-platform intents into a single
/// shortcut action. Returns the share-suggestion token (see ClipSafariPageIntent).
struct SaveFromAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Save from App"
    static let description = IntentDescription("""
        Saves content based on the current app. Pass the current app and the \
        values that app expects:
        • Safari or other — [url]
        • YouTube — ["channel_name:video_title"]
        • Bluesky — [search phrase]
        • Reddit — [search phrase]
        • Music or Spotify — [artist, title]
        • Podcasts — [show, episode_title]
        • X, TikTok, Instagram, or Facebook — [url] (no search; pass the link)
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String

    @Parameter(title: "Values", description: "The field(s) for that app — see the description.")
    var values: [String]

    enum SaveError: Error, CustomLocalizedStringResourceConvertible {
        case missingValues
        case notFound
        case youTubeNotSignedIn

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .missingValues: return "Nothing to save was provided."
            case .notFound: return "Couldn't find a matching item."
            case .youTubeNotSignedIn: return "Sign in to YouTube in Click's settings first."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let cleaned = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let platform = AppNamePlatform.platform(forAppName: app)

        switch platform {
        case .youtube:
            try await saveYouTube(query: cleaned.first)
        case .bluesky:
            try await saveSearch(cleaned.first) { try await BlueskySearchClient().topPostURL(query: $0) }
        case .reddit:
            try await saveSearch(cleaned.first) { try await RedditSearchClient().topPostURL(query: $0) }
        case .music:
            try await saveMedia(.music, creator: cleaned.first, title: cleaned.dropFirst().first)
        case .podcast:
            try await saveMedia(.podcast, creator: cleaned.first, title: cleaned.dropFirst().first)
        case .x, .tiktok, .instagram, .facebook, nil:
            // No free search — expect a URL.
            guard let url = cleaned.first, url.hasPrefix("http") else { throw SaveError.notFound }
            _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url)
        }
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }

    private func saveYouTube(query: String?) async throws {
        guard GoogleAuthClient.shared.isSignedIn else { throw SaveError.youTubeNotSignedIn }
        guard let query, let parsed = YouTubeQuery.parse(query) else { throw SaveError.missingValues }
        let api = YouTubeAPIClient()
        guard let channelID = try await api.searchChannelID(name: parsed.channel) else {
            throw SaveError.notFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: parsed.title)
        guard let match = VideoMatchSelection.bestMatch(title: parsed.title, candidates: candidates) else {
            throw SaveError.notFound
        }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(
            urlString: YouTubeURL.watchURLString(videoID: match.videoID))
    }

    private func saveSearch(_ query: String?, resolve: (String) async throws -> URL) async throws {
        guard let query else { throw SaveError.missingValues }
        guard let url = try? await resolve(query) else { throw SaveError.notFound }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
    }

    private func saveMedia(_ platform: ContentPlatform, creator: String?, title: String?) async throws {
        guard let creator, let title else { throw SaveError.missingValues }
        let item = ReadingListStore.shared.createURLlessMediaItem(
            platform: platform, creator: creator, title: title)
        if let art = await MediaArtFetcher.fetchArtwork(
            creator: creator, title: title, isPodcast: platform == .podcast) {
            ReadingListStore.shared.setThumbnail(art, for: item.id)
        }
    }
}
