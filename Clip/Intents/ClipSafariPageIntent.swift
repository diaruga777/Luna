//
//  ClipSafariPageIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Saves the page currently open in Safari — always the URL persisted by the
/// ClipSafari extension; the optional URL parameter NEVER overrides it. When
/// provided it's a fuzzy prefix cross-check against the tracked URL (guarding
/// against a stale tracked page); when absent, no check runs. Designed for the
/// Action Button shortcut.
struct ClipSafariPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Save Current Safari Page"
    static let description = IntentDescription(
        "Saves the page currently open in Safari to your Queue reading list (requires the Queue Safari extension).")
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
                return "No Safari page tracked yet. Is the Queue extension enabled?"
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

/// Shared best-effort inline save handling for background intents.
enum IntentIngestHelper {
    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after 12 s so the intent finishes promptly in the background. Work cut
    /// off by the timeout is persisted as pending/queued and retried later.
    /// Returns the URL that ended up saved (also for duplicates, which are
    /// already in the list), or nil when the outcome couldn't be determined
    /// before the timeout.
    static func handleSavePressWithTimeout(urlString: String) async -> String? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString
        return await withTaskGroup(of: String?.self) { group in
            group.addTask {
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: urlString, source: .appIntent)
                switch result {
                case .saved(let item): return item.urlString
                case .sentToEreaders(let item): return item.urlString
                case .ignored: return urlString
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
