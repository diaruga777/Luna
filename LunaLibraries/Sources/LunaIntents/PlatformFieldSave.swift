//
//  PlatformFieldSave.swift
//  LunaIntents
//

import LunaModels
import LunaPlatforms
import Foundation

/// Lifted from `SaveFromAppIntent.perform()`'s inline per-platform routing
/// switch: given a platform and the " ; "-joined fields parsed from the model's
/// screen-read response (`SaveResponseParsing.parseFields`), validates the field
/// count for that platform, runs the platform's search (Bluesky/Reddit's own
/// search APIs; X/TikTok/Instagram/Facebook via keyless `SocialPostFinder`), and
/// saves the result — double-save-aware via `doubleSaveActionSurface`. There is
/// no music/podcast case (that platform support was retired in `7c34cd69`).
public enum PlatformFieldSave {

    public enum SaveError: Error {
        /// The search/find step came up empty.
        case notFound
        /// The fields didn't include the values this platform requires.
        case missingValues
    }

    public static func save(
        platform: ContentPlatform, fields: [String], doubleSaveActionSurface: String?
    ) async throws -> IntentIngestHelper.ActionButtonSaveOutcome {
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
            return await IntentIngestHelper.handleSavePress(
                urlString: url.absoluteString, doubleSaveActionSurface: doubleSaveActionSurface)

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
            return await IntentIngestHelper.handleSavePress(
                urlString: url.absoluteString, doubleSaveActionSurface: doubleSaveActionSurface)

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
            return await IntentIngestHelper.handleSavePress(
                urlString: url.absoluteString, doubleSaveActionSurface: doubleSaveActionSurface)
        }
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
