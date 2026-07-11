//
//  PlatformLinkIntents.swift
//  Luna
//
//  App Intent definitions (kept in the app target for App Intents discovery /
//  registration). The shared find-and-save business logic lives in
//  LunaIntents.PlatformPostSave.
//

import AppIntents
import LunaIntents
import LunaPlatforms
import Foundation

struct SaveXPostIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save X Post"
    static let description = IntentDescription(
        "Finds an X (Twitter) post by author handle + a phrase from it (or its time) and saves it.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The author's @handle.") var handle: String?
    @Parameter(title: "Content", description: "A distinctive phrase from the post.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    func perform() async throws -> some IntentResult {
        _ = try await PlatformPostSave.save(
            platform: .x, handle: handle, content: content, timestamp: timestamp,
            doubleSaveActionSurface: nil)
        return .result()
    }
}

struct SaveTikTokIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save TikTok"
    static let description = IntentDescription(
        "Finds a TikTok by creator handle + a phrase from its caption (or its time) and saves it.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The creator's @handle.") var handle: String?
    @Parameter(title: "Caption", description: "A distinctive phrase from the caption.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    func perform() async throws -> some IntentResult {
        _ = try await PlatformPostSave.save(
            platform: .tiktok, handle: handle, content: content, timestamp: timestamp,
            doubleSaveActionSurface: nil)
        return .result()
    }
}

struct SaveInstagramPostIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save Instagram Post"
    static let description = IntentDescription(
        "Finds an Instagram post/reel by account handle + a phrase from its caption and saves it.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Handle", description: "The account's @handle.") var handle: String?
    @Parameter(title: "Caption", description: "A distinctive phrase from the caption.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    func perform() async throws -> some IntentResult {
        _ = try await PlatformPostSave.save(
            platform: .instagram, handle: handle, content: content, timestamp: timestamp,
            doubleSaveActionSurface: nil)
        return .result()
    }
}

struct SaveFacebookPostIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save Facebook Post"
    static let description = IntentDescription(
        "Finds a Facebook post/video by page or author + a phrase from it and saves it.")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "Author or Page", description: "The author / page name or handle.") var handle: String?
    @Parameter(title: "Content", description: "A distinctive phrase from the post.") var content: String?
    @Parameter(title: "Posted", description: "Optional: the post's date/time as shown.") var timestamp: String?

    func perform() async throws -> some IntentResult {
        _ = try await PlatformPostSave.save(
            platform: .facebook, handle: handle, content: content, timestamp: timestamp,
            doubleSaveActionSurface: nil)
        return .result()
    }
}
