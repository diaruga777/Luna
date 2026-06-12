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

        await IntentIngestHelper.handleSavePressWithTimeout(urlString: tracked)
        return .result()
    }
}

/// Shared best-effort inline save handling for background intents.
enum IntentIngestHelper {
    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after 12 s so the intent finishes promptly in the background. Work cut
    /// off by the timeout is persisted as pending/queued and retried later.
    static func handleSavePressWithTimeout(urlString: String) async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                _ = await ReadingListIngestor.shared.handleSavePress(urlString: urlString)
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
            }
            _ = await group.next()
            group.cancelAll()
        }
    }
}
