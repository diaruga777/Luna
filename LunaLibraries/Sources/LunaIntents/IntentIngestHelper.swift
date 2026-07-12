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

    /// What an Action Button save press produced, for the Provide Context /
    /// Save App Intents.
    public enum ActionButtonSaveOutcome {
        /// Save/send handled (or duplicate). `savedURLString` is the URL that
        /// ended up saved, nil when the outcome couldn't be determined before
        /// the timeout.
        case completed(savedURLString: String?)
        /// Double save with "ask every time" — the pending friend prompt is
        /// recorded; the intent should foreground the app so the friend
        /// selector can appear. `savedURLString` is the saved item's URL (the
        /// item exists before the prompt is answered).
        case friendPromptRequested(savedURLString: String)
    }

    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after 12 s so the intent finishes promptly in the background. Work cut
    /// off by the timeout is persisted as pending/queued and retried later.
    /// Returns the URL that ended up saved (also for duplicates, which are
    /// already in the list), or nil when the outcome couldn't be determined
    /// before the timeout.
    public static func handleSavePressWithTimeout(urlString: String) async -> String? {
        switch await savePressRacingTimeout(urlString: urlString, doubleSaveActionSurface: nil) {
        case .some(.saved(let item)), .some(.sentToEreaders(let item)),
             .some(.sentToFriends(let item)), .some(.friendPromptRequested(let item)):
            return item.urlString
        case .some(.ignored):
            return urlString
        case nil:
            return nil
        }
    }

    /// The Action Button (Save App Intent) variant: same timeout-raced save, but
    /// with the configured double-save action armed for `surface`, and a result
    /// that distinguishes the "open the friend selector" hand-off.
    public static func handleActionButtonSavePress(
        urlString: String, doubleSaveActionSurface surface: String
    ) async -> ActionButtonSaveOutcome {
        switch await savePressRacingTimeout(urlString: urlString, doubleSaveActionSurface: surface) {
        case .some(.friendPromptRequested(let item)):
            return .friendPromptRequested(savedURLString: item.urlString)
        case .some(.saved(let item)), .some(.sentToEreaders(let item)), .some(.sentToFriends(let item)):
            return .completed(savedURLString: item.urlString)
        case .some(.ignored):
            return .completed(savedURLString: urlString)
        case nil:
            return .completed(savedURLString: nil)
        }
    }

    /// Convenience for callers with an optional double-save surface: routes
    /// through `handleActionButtonSavePress` when a surface is armed, else
    /// `handleSavePressWithTimeout` — mirroring the decision the Provide
    /// Context / Save intents make (double-save only armed for eligible
    /// surfaces).
    public static func handleSavePress(
        urlString: String, doubleSaveActionSurface surface: String?
    ) async -> ActionButtonSaveOutcome {
        guard let surface else {
            return .completed(savedURLString: await handleSavePressWithTimeout(urlString: urlString))
        }
        return await handleActionButtonSavePress(urlString: urlString, doubleSaveActionSurface: surface)
    }

    /// Runs `handleSavePress` raced against a 12 s timeout; nil ⇒ timed out.
    private static func savePressRacingTimeout(
        urlString: String, doubleSaveActionSurface: String?
    ) async -> ReadingListIngestor.SavePressResult? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return .ignored }
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
            @Sendable func finish(_ value: ReadingListIngestor.SavePressResult?) {
                resumeLock.lock()
                let first = !resumed
                resumed = true
                resumeLock.unlock()
                if first { continuation.resume(returning: value) }
            }
            Task {
                let result = await ReadingListIngestor.shared.handleSavePress(
                    urlString: urlString, source: .appIntent,
                    doubleSaveActionSurface: doubleSaveActionSurface)
                finish(result)
            }
            Task {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                finish(nil)
            }
        }
    }
}
