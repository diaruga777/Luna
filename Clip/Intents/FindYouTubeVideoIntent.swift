//
//  FindYouTubeVideoIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a YouTube video from a channel name + video title via the YouTube Data
/// API and saves it to the reading list. Matching is lenient (prefix/fuzzy).
/// Requires the YouTube sign-in from Settings.
struct FindYouTubeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Save YouTube Video"
    static let description = IntentDescription(
        "Finds a video by channel name + title on YouTube and saves it to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Channel", description: "The channel name — e.g. \"Veritasium\".")
    var channel: String

    @Parameter(title: "Title", description: "The video title (or a distinctive phrase from it).")
    var title: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notSignedIn
        case badQuery
        case channelNotFound
        case videoNotFound

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notSignedIn:
                return "Sign in to YouTube in Click's settings first."
            case .badQuery:
                return "Enter both a channel name and a video title."
            case .channelNotFound:
                return "Couldn't find that channel on YouTube."
            case .videoNotFound:
                return "Couldn't find a matching video on that channel."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        guard GoogleAuthClient.shared.isSignedIn else { throw FindError.notSignedIn }
        let channelName = channel.trimmingCharacters(in: .whitespacesAndNewlines)
        let videoTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !channelName.isEmpty, !videoTitle.isEmpty else { throw FindError.badQuery }
        let api = YouTubeAPIClient()

        guard let channelID = try await api.searchChannelID(name: channelName) else {
            throw FindError.channelNotFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: videoTitle)
        guard let match = VideoMatchSelection.bestMatch(title: videoTitle, candidates: candidates)
        else { throw FindError.videoNotFound }

        let urlString = YouTubeURL.watchURLString(videoID: match.videoID)
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString)
        // Return the share-suggestion token (see ClipSafariPageIntent).
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}
