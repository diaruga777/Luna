//
//  PlatformLinkIntents.swift
//  Clip
//

import AppIntents
import Foundation

/// X, TikTok, Instagram, and Facebook have no free public search, so a post can
/// only be captured from its link (the share sheet / clipboard / on-screen URL).
/// These intents take that link and save it — one per platform so the bundled
/// shortcut's per-app branch is explicit. The link is saved verbatim; the
/// per-platform classifier renders it correctly in the reading list.
private enum PlatformLinkSave {
    static func save(_ link: String?) async throws -> String {
        let trimmed = (link ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("http") else { throw PlatformLinkError.notALink }
        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: trimmed)
        return ShareSuggestionStore.shared.pendingSuggestionToken()
    }
}

enum PlatformLinkError: Error, CustomLocalizedStringResourceConvertible {
    case notALink
    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .notALink: return "Pass the post's link (it must start with http)."
        }
    }
}

struct SaveXPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save X Post"
    static let description = IntentDescription(
        "Saves an X (Twitter) post from its link to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Post Link", description: "The x.com / twitter.com post URL.")
    var link: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformLinkSave.save(link))
    }
}

struct SaveTikTokIntent: AppIntent {
    static let title: LocalizedStringResource = "Save TikTok"
    static let description = IntentDescription(
        "Saves a TikTok from its link to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Video Link", description: "The tiktok.com video URL (any share link works).")
    var link: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformLinkSave.save(link))
    }
}

struct SaveInstagramPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Instagram Post"
    static let description = IntentDescription(
        "Saves an Instagram post or reel from its link to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Post Link", description: "The instagram.com post / reel URL.")
    var link: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformLinkSave.save(link))
    }
}

struct SaveFacebookPostIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Facebook Post"
    static let description = IntentDescription(
        "Saves a Facebook post or video from its link to your Click reading list.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Post Link", description: "The facebook.com post / video URL.")
    var link: String?

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await PlatformLinkSave.save(link))
    }
}
