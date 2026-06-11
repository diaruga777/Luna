//
//  ClipSafariPageIntent.swift
//  Clip
//

import AppIntents
import Foundation

/// Saves the page currently open in Safari — always the URL persisted by the
/// ClipSafari extension. The optional URL parameter is only a cross-check: when
/// provided, its base (host) must match the tracked URL, guarding against a
/// stale tracked page. Designed for the Action Button shortcut.
struct ClipSafariPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Clip Current Safari Page"
    static let description = IntentDescription(
        "Saves the page currently open in Safari to your Clip reading list (requires the Clip Safari extension).")
    static let openAppWhenRun: Bool = false

    @Parameter(title: "App", description: "The current app, from Get Current App. Used to check you're in Safari.")
    var app: String?

    @Parameter(title: "Verification URL", description: "Optional. If provided, its site must match the tracked Safari page.")
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
                return "No Safari page tracked yet. Is the Clip extension enabled?"
            case .trackedURLMismatch:
                return "The tracked Safari page doesn't match the current site — nothing saved."
            }
        }
    }

    func perform() async throws -> some IntentResult {
        let isSafari = app?.localizedCaseInsensitiveContains("safari") ?? true
        guard isSafari else { throw ClipError.notInSafari }

        guard let tracked = SafariURLStore.lastURL else { throw ClipError.noTrackedURL }

        if let url,
           let verifyHost = url.host?.lowercased(),
           let trackedHost = URL(string: tracked)?.host?.lowercased(),
           verifyHost != trackedHost {
            throw ClipError.trackedURLMismatch
        }

        let item = ReadingListStore.shared.add(urlString: tracked)
        _ = await IntentIngestHelper.ingestWithTimeout(item)
        return .result()
    }
}

/// Shared best-effort inline ingestion for background intents.
enum IntentIngestHelper {
    /// Runs ingestion, giving up (but not cancelling persistence) after 12 s so
    /// the intent finishes promptly in the background.
    static func ingestWithTimeout(_ item: ReadingListItem) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                await ReadingListIngestor.shared.ingest(item)
                return true
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                return false
            }
            let finished = await group.next() ?? false
            group.cancelAll()
            return finished
        }
    }
}
