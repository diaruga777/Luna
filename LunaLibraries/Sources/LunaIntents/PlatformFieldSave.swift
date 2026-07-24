//
//  PlatformFieldSave.swift
//  LunaIntents
//

import LunaModels
import LunaPlatforms
import Foundation

/// The Save intent's per-platform save routing: given a platform and the
/// " ; "-joined fields parsed from the model's
/// screen-read response (`SaveResponseParsing.parseFields`), validates the field
/// count for that platform, runs the platform's search (Bluesky/Reddit's own
/// search APIs; X/TikTok/Instagram/Facebook via keyless `SocialPostFinder`), and
/// saves the result — double-save-aware via `doubleSaveActionSurface`.
/// `LunaPlatforms.ContentPlatform` has no music/podcast case.
public enum PlatformFieldSave {

    /// Keeps the URL resolved by the platform search independent from the save
    /// result. A duplicate/double-save may legitimately return no saved URL
    /// before the App Intent timeout, but media handoff must still use the URL
    /// the finder already resolved.
    public struct Result {
        public let resolvedURLString: String
        public let outcome: IntentIngestHelper.ActionButtonSaveOutcome

        public init(
            resolvedURLString: String,
            outcome: IntentIngestHelper.ActionButtonSaveOutcome
        ) {
            self.resolvedURLString = resolvedURLString
            self.outcome = outcome
        }
    }

    public enum SaveError: Error {
        /// The search/find step came up empty.
        case notFound
        /// The fields didn't include the values this platform requires.
        case missingValues
    }

    public static func save(
        platform: ContentPlatform, fields: [String], doubleSaveActionSurface: String?,
        saveTimeout: TimeInterval = IntentSaveTimeout.standard
    ) async throws -> Result {
        switch platform {
        case .bluesky:
            // handle + phrase.
            guard let handle = fields.first, !handle.isEmpty,
                  let phrase = fields.dropFirst().first, !phrase.isEmpty
            else { throw SaveError.missingValues }
            let query = BlueskyPostQuery.searchQuery(handle: handle, text: phrase)
            guard !query.isEmpty else { throw SaveError.missingValues }
            guard let url = try? await BlueskySearchClient().topPostURL(query: query)
            else { throw SaveError.notFound }
            return await saveResolvedURL(
                url, doubleSaveActionSurface: doubleSaveActionSurface,
                saveTimeout: saveTimeout)

        case .reddit:
            // subreddit + title, optional author.
            guard let subreddit = fields.first, !subreddit.isEmpty,
                  let title = fields.dropFirst().first, !title.isEmpty
            else { throw SaveError.missingValues }
            let query = RedditPostQuery.searchQuery(
                subreddit: subreddit, title: title, author: fields.dropFirst(2).first)
            guard !query.isEmpty else { throw SaveError.missingValues }
            guard let url = try? await RedditSearchClient().topPostURL(query: query)
            else { throw SaveError.notFound }
            return await saveResolvedURL(
                url, doubleSaveActionSurface: doubleSaveActionSurface,
                saveTimeout: saveTimeout)

        case .x, .tiktok, .instagram, .facebook:
            // handle + phrase, optional date.
            guard let finderPlatform = finderPlatform(for: platform) else { throw SaveError.notFound }
            guard let handle = fields.first, !handle.isEmpty,
                  let phrase = fields.dropFirst().first, !phrase.isEmpty
            else { throw SaveError.missingValues }
            guard let url = await SocialPostFinder.findPostURL(
                platform: finderPlatform, handle: handle,
                content: phrase, timestamp: fields.dropFirst(2).first)
            else { throw SaveError.notFound }
            return await saveResolvedURL(
                url, doubleSaveActionSurface: doubleSaveActionSurface,
                saveTimeout: saveTimeout)
        case .youtube, .web:
            // YouTube saves arrive as URLs (Safari/on-screen URL extraction); the
            // screenshot search path has no stable keyless video search contract.
            // Direct web media likewise already arrives as its URL.
            throw SaveError.notFound
        }
    }

    private static func saveResolvedURL(
        _ url: URL, doubleSaveActionSurface: String?, saveTimeout: TimeInterval
    ) async -> Result {
        let urlString = url.absoluteString
        let outcome = await IntentIngestHelper.handleSavePress(
            urlString: urlString, doubleSaveActionSurface: doubleSaveActionSurface,
            timeout: saveTimeout)
        return Result(resolvedURLString: urlString, outcome: outcome)
    }

    private static func finderPlatform(for platform: ContentPlatform) -> SocialPostFinder.Platform? {
        switch platform {
        case .x: return .x
        case .tiktok: return .tiktok
        case .instagram: return .instagram
        case .facebook: return .facebook
        default: return nil
        }
    }
}
