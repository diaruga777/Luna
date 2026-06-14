//
//  FindYouTubeVideoIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a YouTube video from a "channel:title" string (split on the first
/// colon; the title may contain more colons) via the YouTube Data API and
/// saves it to the reading list. Matching is lenient (prefix/fuzzy).
/// Requires the YouTube sign-in from Settings.
struct FindYouTubeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Save YouTube Video"
    static let description = IntentDescription(
        "Finds a video from \"channel:title\" on YouTube and saves it to your Clip reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(
        title: "Video",
        description: "\"channel:title\" — e.g. \"Veritasium:The science of\". A leading @ and any ellipsis are ignored.")
    var query: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notSignedIn
        case badQuery
        case channelNotFound
        case videoNotFound

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notSignedIn:
                return "Sign in to YouTube in Clip's settings first."
            case .badQuery:
                return "Use \"channel:title\" — for example \"Veritasium:black holes\"."
            case .channelNotFound:
                return "Couldn't find that channel on YouTube."
            case .videoNotFound:
                return "Couldn't find a matching video on that channel."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        guard GoogleAuthClient.shared.isSignedIn else { throw FindError.notSignedIn }
        guard let parsed = YouTubeQuery.parse(query) else { throw FindError.badQuery }
        let api = YouTubeAPIClient()

        guard let channelID = try await api.searchChannelID(name: parsed.channel) else {
            throw FindError.channelNotFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: parsed.title)
        guard let match = VideoMatchSelection.bestMatch(title: parsed.title, candidates: candidates)
        else { throw FindError.videoNotFound }

        let urlString = YouTubeURL.watchURLString(videoID: match.videoID)
        let savedURL = await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString)
        return .result(value: savedURL)
    }
}
