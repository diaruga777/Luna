//
//  IntentIngestHelper.swift
//  LunaIntents
//

import LunaReadingList
import LunaInterop
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
        /// the timeout. `needsInstallOwner` is the owning app of a PAID
        /// cross-surface save when that app isn't installed — the intent's
        /// dialog mentions installing it (the item IS saved either way).
        case completed(savedURLString: String?, needsInstallOwner: InteropSurface? = nil)
        /// Double save with "ask every time" — the pending friend prompt is
        /// recorded; the intent should foreground the app so the friend
        /// selector can appear. `savedURLString` is the saved item's URL (the
        /// item exists before the prompt is answered).
        case friendPromptRequested(savedURLString: String)
        /// Unpaid cross-surface save (`claudedocs/interop-purchase.md`) — the
        /// item was DISCARDED. The intent throws an error dialog naming the
        /// owning app and the unlock.
        case blockedByInterop(owner: InteropSurface, ownerInstalled: Bool)
    }

    /// The user-facing dialog for a `blockedByInterop` save — used verbatim by
    /// the Save / Provide Context intents' thrown errors. Names the owning app,
    /// the unlock, and the direct alternative (sharing to the owning app).
    public static func blockedDialogText(
        owner: InteropSurface, currentAppName: String
    ) -> String {
        "This link is handled by \(owner.displayName). Open \(currentAppName) to unlock "
            + "cross-app saving ($1.99), or share it to \(owner.displayName) instead."
    }

    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after 12 s so the intent finishes promptly in the background. Work cut
    /// off by the timeout is persisted as pending/queued and retried later.
    /// Returns the URL that ended up saved (also for duplicates, which are
    /// already in the list), or nil when the outcome couldn't be determined
    /// before the timeout. Interop-blocked saves surface through the
    /// `ActionButtonSaveOutcome` variant; this URL-only convenience reports
    /// them as "nothing saved".
    public static func handleSavePressWithTimeout(urlString: String) async -> String? {
        switch await savePressRacingTimeout(urlString: urlString, doubleSaveActionSurface: nil) {
        case .some(.saved(let item)), .some(.savedNeedsOwnerInstall(let item, _)),
             .some(.sentToEreaders(let item)),
             .some(.sentToFriends(let item)), .some(.friendPromptRequested(let item)):
            return item.urlString
        case .some(.ignored):
            return urlString
        case .some(.blockedByInterop), nil:
            return nil
        }
    }

    /// The Action Button (Save App Intent) variant: same timeout-raced save, but
    /// with the configured double-save action armed for `surface`, and a result
    /// that distinguishes the "open the friend selector" hand-off.
    public static func handleActionButtonSavePress(
        urlString: String, doubleSaveActionSurface surface: String
    ) async -> ActionButtonSaveOutcome {
        actionButtonOutcome(from: await savePressRacingTimeout(
            urlString: urlString, doubleSaveActionSurface: surface),
            ignoredURLString: urlString)
    }

    /// Converts the full ingest result into the intent-facing result without
    /// erasing interop decisions. Kept internal so unit tests can lock the
    /// important `.blockedByInterop` mapping without running a live ingest.
    static func actionButtonOutcome(
        from result: ReadingListIngestor.SavePressResult?,
        ignoredURLString: String = ""
    ) -> ActionButtonSaveOutcome {
        switch result {
        case .some(.friendPromptRequested(let item)):
            return .friendPromptRequested(savedURLString: item.urlString)
        case let .some(.savedNeedsOwnerInstall(item, owner)):
            return .completed(savedURLString: item.urlString, needsInstallOwner: owner)
        case .some(.saved(let item)), .some(.sentToEreaders(let item)), .some(.sentToFriends(let item)):
            return .completed(savedURLString: item.urlString)
        case let .some(.blockedByInterop(owner, ownerInstalled)):
            return .blockedByInterop(owner: owner, ownerInstalled: ownerInstalled)
        case .some(.ignored):
            return .completed(savedURLString: ignoredURLString)
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
        // Even when double-save is not armed, retain the full result. The old
        // URL-only convenience mapped an unpaid interop block to nil and then
        // incorrectly reported `.completed(nil)` to Shortcuts.
        actionButtonOutcome(from: await savePressRacingTimeout(
            urlString: urlString, doubleSaveActionSurface: surface),
            ignoredURLString: urlString)
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
