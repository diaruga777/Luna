//
//  IntentIngestHelper.swift
//  LuneIntents
//

import LuneReadingList
import LuneURLClassification
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
