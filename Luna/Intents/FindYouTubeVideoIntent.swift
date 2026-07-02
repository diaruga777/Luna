//
//  FindYouTubeVideoIntent.swift
//  Luna
//

import LunaIntents
import LunaYouTubeAPI
import LunaURLClassification
import AppIntents
import Foundation

/// Finds a YouTube video from a channel name + video title via the YouTube Data
/// API and saves it to the reading list. Matching is lenient (prefix/fuzzy).
/// Requires the YouTube sign-in from Settings.
public struct FindYouTubeVideoIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save YouTube Video"
    public static let description = IntentDescription(
        "Finds a video by channel name + title on YouTube and saves it to your Luna reading list.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Channel", description: "The channel name — e.g. \"Veritasium\".")
    public var channel: String

    @Parameter(title: "Title", description: "The video title (or a distinctive phrase from it).")
    public var title: String

    public enum FindError: Error, CustomLocalizedStringResourceConvertible {
        case notSignedIn
        case badQuery
        case channelNotFound
        case videoNotFound

        public var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notSignedIn:
                return "Sign in to YouTube in Luna's settings first."
            case .badQuery:
                return "Enter both a channel name and a video title."
            case .channelNotFound:
                return "Couldn't find that channel on YouTube."
            case .videoNotFound:
                return "Couldn't find a matching video on that channel."
            }
        }
    }

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        do {
            _ = try await YouTubeVideoSave.findAndSave(channel: channel, title: title)
        } catch let failure as YouTubeVideoSave.FindFailure {
            throw FindError(failure)
        }
        return .result(value: "Saved to Luna.")
    }
}

private extension FindYouTubeVideoIntent.FindError {
    init(_ failure: YouTubeVideoSave.FindFailure) {
        switch failure {
        case .notSignedIn: self = .notSignedIn
        case .badQuery: self = .badQuery
        case .channelNotFound: self = .channelNotFound
        case .videoNotFound: self = .videoNotFound
        }
    }
}
