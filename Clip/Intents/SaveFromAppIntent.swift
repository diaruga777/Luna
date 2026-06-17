//
//  SaveFromAppIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// One generic save action that adapts to the current app. Pass the current app
/// (from Get Current App) and the ordered values that app needs — the per-app
/// layout is documented below. Bridges the per-platform intents into a single
/// shortcut action. Returns the share-suggestion token (see ClipSafariPageIntent).
struct SaveFromAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Save from App"
    static let description = IntentDescription("""
        Saves content based on the current app. Pass the current app and the \
        ordered values it expects:
        • Safari or other — [link]
        • YouTube — [channel, title]
        • Bluesky — [handle, text]
        • Reddit — [subreddit, title, author?]
        • Music or Spotify — [artist, title]
        • Podcasts — [show, episode title]
        • X, TikTok, Instagram, or Facebook — [handle, content phrase, time?]
        """)
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App.")
    var app: String?

    @Parameter(title: "Values", description: "The ordered field(s) for that app — see the description.")
    var values: [String]?

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
        guard let app else { throw SaveError.missingValues }
        let cleaned = (values ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let platform = AppNamePlatform.platform(forAppName: app)

        switch platform {
        case .youtube:
            try await saveYouTube(channel: cleaned.first, title: cleaned.dropFirst().first)
        case .bluesky:
            let query = BlueskyPostQuery.searchQuery(
                handle: cleaned.first ?? "", text: cleaned.dropFirst().first ?? "")
            try await saveSearch(query) { try await BlueskySearchClient().topPostURL(query: $0) }
        case .reddit:
            let query = RedditPostQuery.searchQuery(
                subreddit: cleaned.first ?? "", title: cleaned.dropFirst().first ?? "",
                author: cleaned.dropFirst(2).first)
            try await saveSearch(query) { try await RedditSearchClient().topPostURL(query: $0) }
        case .music:
            try await saveMedia(.music, creator: cleaned.first, title: cleaned.dropFirst().first)
        case .podcast:
            try await saveMedia(.podcast, creator: cleaned.first, title: cleaned.dropFirst().first)
        case .x, .tiktok, .instagram, .facebook:
            // No public search API: find the post from [handle, content, time?].
            guard let finderPlatform = Self.finderPlatform(for: platform) else { throw SaveError.notFound }
            guard let url = await SocialPostFinder.findPostURL(
                platform: finderPlatform, handle: cleaned.first ?? "",
                content: cleaned.dropFirst().first, timestamp: cleaned.dropFirst(2).first)
            else { throw SaveError.notFound }
            _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        case nil:
            // Safari / unknown: expect a link.
            guard let url = cleaned.first, url.hasPrefix("http") else { throw SaveError.notFound }
            _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url)
        }
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }

    private static func finderPlatform(for platform: ContentPlatform?) -> SocialPostFinder.Platform? {
        switch platform {
        case .x: return .x
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .facebook: return .facebook
        default: return nil
        }
    }

    private func saveYouTube(channel: String?, title: String?) async throws {
        guard GoogleAuthClient.shared.isSignedIn else { throw SaveError.youTubeNotSignedIn }
        guard let channel, let title, !channel.isEmpty, !title.isEmpty else {
            throw SaveError.missingValues
        }
        let api = YouTubeAPIClient()
        guard let channelID = try await api.searchChannelID(name: channel) else {
            throw SaveError.notFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: title)
        guard let match = VideoMatchSelection.bestMatch(title: title, candidates: candidates) else {
            throw SaveError.notFound
        }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(
            urlString: YouTubeURL.watchURLString(videoID: match.videoID))
    }

    private func saveSearch(_ query: String, resolve: (String) async throws -> URL) async throws {
        guard !query.isEmpty else { throw SaveError.missingValues }
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
