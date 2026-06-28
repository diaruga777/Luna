//
//  PlatformLinkIntents.swift
//  Clip
//

import ClipSocial
import ClipPlatforms
import AppIntents
import Foundation

/// X, TikTok, Instagram, and Facebook have no free public search API, so these
/// intents take the author handle plus a content snippet and/or a timestamp and
/// try hard to FIND the original post's link (keyless DuckDuckGo HTML search via
/// `SocialPostFinder`), then save it. One intent per platform so the bundled
/// shortcut's per-app branch is explicit.
private enum PlatformPostSave {
    public static func save(
        platform: SocialPostFinder.Platform, handle: String?, content: String?, timestamp: String?
    ) async throws -> String {
        guard let handle, !handle.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw PlatformPostError.missingHandle
        }
        guard let url = await SocialPostFinder.findPostURL(
            platform: platform, handle: handle, content: content, timestamp: timestamp)
        else { throw PlatformPostError.notFound }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: url.absoluteString)
        return ShareSuggestionStore.shared.pendingSuggestionToken()
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

public struct SaveXPostIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save X Post"
    public static let description = IntentDescription(
        "Finds an X (Twitter) post by author handle + a phrase from it (or its time) and saves it.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The author's @handle.") var handle: String?
    @Parameter(title: "Content", description: "A distinctive phrase from the post.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformPostSave.save(
            platform: .x, handle: handle, content: content, timestamp: timestamp))
    }
}

public struct SaveTikTokIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save TikTok"
    public static let description = IntentDescription(
        "Finds a TikTok by creator handle + a phrase from its caption (or its time) and saves it.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The creator's @handle.") var handle: String?
    @Parameter(title: "Caption", description: "A distinctive phrase from the caption.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformPostSave.save(
            platform: .tiktok, handle: handle, content: content, timestamp: timestamp))
    }
}

public struct SaveInstagramPostIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Instagram Post"
    public static let description = IntentDescription(
        "Finds an Instagram post/reel by account handle + a phrase from its caption and saves it.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The account's @handle.") var handle: String?
    @Parameter(title: "Caption", description: "A distinctive phrase from the caption.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformPostSave.save(
            platform: .instagram, handle: handle, content: content, timestamp: timestamp))
    }
}

public struct SaveFacebookPostIntent: AppIntent {
    public init() {}
    public static let title: LocalizedStringResource = "Save Facebook Post"
    public static let description = IntentDescription(
        "Finds a Facebook post/video by page or author + a phrase from it and saves it.")
    public static let openAppWhenRun: Bool = false

    @Parameter(title: "Author or Page", description: "The author / page name or handle.") var handle: String?
    @Parameter(title: "Content", description: "A distinctive phrase from the post.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    public func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformPostSave.save(
            platform: .facebook, handle: handle, content: content, timestamp: timestamp))
    }
}
