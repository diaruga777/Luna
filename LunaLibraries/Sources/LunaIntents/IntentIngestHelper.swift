//
//  IntentIngestHelper.swift
//  LunaIntents
//

import LunaReadingList
import LunaURLClassification
import Foundation

/// Shared best-effort inline save handling for background intents. The App Intent
/// structs live in the app target (for discovery); this is the business logic they
/// call into.
public enum IntentIngestHelper {
    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after 12 s so the intent finishes promptly in the background. Work cut
    /// off by the timeout is persisted as pending/queued and retried later.
    /// Returns the URL that ended up saved (also for duplicates, which are
    /// already in the list), or nil when the outcome couldn't be determined
    /// before the timeout.
    public static func handleSavePressWithTimeout(urlString: String) async -> String? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return nil }
        let urlString = url.absoluteString
        // NOT a task group: `withTaskGroup` awaits ALL children before returning,
        // and the save leg isn't reliably cancellation-responsive (web-archive
        // capture, image downloads), so a group blows through the 12 s budget.
        // Race unstructured tasks instead and resume on whichever finishes first;
        // a timed-out save keeps running and persists its item as pending/queued
        // for a later retry, exactly as documented above.
        let resumeLock = NSLock()
        var resumed = false
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: String?) {
                resumeLock.lock()
                let first = !resumed
                resumed = true
                resumeLock.unlock()
                if first { continuation.resume(returning: value) }
            }
            Task {
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: urlString, source: .appIntent)
                switch result {
                case .saved(let item), .sentToEreaders(let item):
                    finish(item.urlString)
                case .ignored:
                    finish(urlString)
                }
            }
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                finish(nil)
            }
        }
    }
}
