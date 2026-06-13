//
//  FindYouTubeVideoIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Finds a YouTube video by channel name + title (exact, then title-prefix,
/// then best match) via the YouTube Data API and saves it to the reading list.
/// Requires the YouTube sign-in from Settings.
struct FindYouTubeVideoIntent: AppIntent {
    static let title: LocalizedStringResource = "Save YouTube Video"
    static let description = IntentDescription(
        "Finds a video by channel and title on YouTube and saves it to your Clip reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Channel", description: "The channel's name.")
    var channel: String

    @Parameter(title: "Title", description: "The video's title (a prefix is enough).")
    var videoTitle: String

    enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notSignedIn
        case channelNotFound
        case videoNotFound

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notSignedIn:
                return "Sign in to YouTube in Clip's settings first."
            case .channelNotFound:
                return "Couldn't find that channel on YouTube."
            case .videoNotFound:
                return "Couldn't find a matching video on that channel."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String?> {
        guard GoogleAuthClient.shared.isSignedIn else { throw FindError.notSignedIn }
        let api = YouTubeAPIClient()

        guard let channelID = try await api.searchChannelID(name: channel) else {
            throw FindError.channelNotFound
        }
        let candidates = try await api.searchVideos(channelID: channelID, query: videoTitle)
        guard let match = VideoMatchSelection.bestMatch(title: videoTitle, candidates: candidates)
        else { throw FindError.videoNotFound }

        let urlString = YouTubeURL.watchURLString(videoID: match.videoID)
        let savedURL = await IntentIngestHelper.handleSavePressWithTimeout(urlString: urlString)
        return .result(value: savedURL)
    }
}
