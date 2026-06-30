//
//  ClipSafariPageIntent.swift
//  Clip
//
//  App Intent definition (kept in the app target for App Intents discovery). The
//  save business logic lives in ClipIntents.IntentIngestHelper.
//

import AppIntents
import ClipIntents
import ClipSocial
import ClipStorage
import Foundation

/// Saves the page currently open in Safari — always the URL persisted by the
/// ClipSafari extension; the optional URL parameter NEVER overrides it. When
/// provided it's a fuzzy prefix cross-check against the tracked URL (guarding
/// against a stale tracked page); when absent, no check runs. Designed for the
/// Action Button shortcut.
struct ClipSafariPageIntent: AppIntent {
    init() {}
    static let title: LocalizedStringResource = "Save Current Safari Page"
    static let description = IntentDescription(
        "Saves the page currently open in Safari to your Quartz reading list (requires the Quartz Safari extension).")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App. Used to check you're in Safari.")
    var app: String?

    @Parameter(title: "Verification URL", description: "Optional. If provided, it must be a (fuzzy) prefix match of the tracked Safari page. It never overrides what gets saved.")
    var url: URL?

    enum ClipError: Error, CustomLocalizedStringResourceConvertible {
        case notInSafari
        case noTrackedURL
        case trackedURLMismatch

        var localizedStringResource: LocalizedStringResource {
            switch self {
            case .notInSafari:
                return "Not in Safari — nothing saved."
            case .noTrackedURL:
                return "No Safari page tracked yet. Is the Quartz extension enabled?"
            case .trackedURLMismatch:
                return "The tracked Safari page doesn't match the current site — nothing saved."
            }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let isSafari = app?.localizedCaseInsensitiveContains("safari") ?? true
        guard isSafari else { throw ClipError.notInSafari }

        guard let tracked = SafariURLStore.lastURL else { throw ClipError.noTrackedURL }

        if let url,
           !URLPrefixMatch.fuzzyPrefixMatches(provided: url.absoluteString, tracked: tracked) {
            throw ClipError.trackedURLMismatch
        }

        _ = await IntentIngestHelper.handleSavePressWithTimeout(urlString: tracked)
        // Return the share-suggestion token so the shortcut can offer the right
        // menu ("" none / "3:name" yes-always-no / "2:name" yes-no).
        return .result(value: ShareSuggestionStore.shared.pendingSuggestionToken())
    }
}
