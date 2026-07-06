//
//  PlatformPostSave.swift
//  LunaIntents
//

import LunaPlatforms
import AppIntents
import Foundation

/// X, TikTok, Instagram, and Facebook have no free public search API, so the
/// per-platform save intents take the author handle plus a content snippet and/or
/// a timestamp and try hard to FIND the original post's link (keyless DuckDuckGo
/// HTML search via `SocialPostFinder`), then save it. The intent structs live in
/// the app target (for App Intents discovery); this is the shared business logic.
public enum PlatformPostSave {
    public static func save(
        platform: SocialPostFinder.Platform, handle: String?, content: String?, timestamp: String?
    ) async throws {
        guard let handle, !handle.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PlatformPostError.missingHandle
        }
        guard let url = await SocialPostFinder.findPostURL(
            platform: platform, handle: handle, content: content, timestamp: timestamp)
        else { throw PlatformPostError.notFound }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
    }
}

public enum PlatformPostError: Error, CustomLocalizedStringResourceConvertible {
    case missingHandle
    case notFound
    public var localizedStringResource: LocalizedStringResource {
        switch self {
        case .missingHandle: return "Enter the author's handle."
        case .notFound: return "Couldn't find that post — add more of its text."
        }
    }
}
