//
//  IntentIngestHelper.swift
//  LunaIntents
//

import LunaReadingList
import LunaStorage
import LunaIngest
import LunaModels
import LunaURLClassification
import Foundation

/// How long an App-Intent save press may wait for its classified outcome before
/// the intent gives up and lets the work finish in the background.
///
/// The wait is what makes a real failure reportable (`IntentSaveVerification`),
/// so longer is BETTER — it is bounded only by what the intent's runtime allows.
public enum IntentSaveTimeout {

    /// The ordinary background budget. An app intent gets ~30 s in total, and the
    /// save is only the first leg — the media handoff (preflight HEAD + transfer)
    /// and the return trip come after it — so the save may not eat the budget.
    public static let standard: TimeInterval = 12

    /// Provide Context's whole normal-runtime fast path. This leaves roughly
    /// ten seconds of the system's traditional 30-second budget for cooperative
    /// cancellation, checkpoint encoding, and returning the result to Shortcuts.
    public static let provideContext: TimeInterval = 20

    /// Under SaveIntent's system extended runtime (`LongRunningIntent`, iOS 27+)
    /// there is no 30 s ceiling to race, so wait past the ingest pipeline's OWN
    /// hard timeout. Derived from it deliberately: the pipeline always resolves
    /// within `processTimeout`, so this makes the race a backstop rather than the
    /// normal exit, and a failed fetch is reported instead of being reported as a
    /// success that left a `.failed` item behind.
    public static let extendedRuntime: TimeInterval = IngestPipeline.processTimeout + 2
}

/// Shared inline save handling for background intents. The App Intent structs
/// live in the app target (for discovery); this is the business logic they call
/// into.
///
/// Every save press routed through here is VERIFIED against the store before it
/// is reported as done: an intent may not tell Shortcuts "saved" while the app
/// holds nothing, or holds only a failure (`IntentSaveVerification`).
public enum IntentIngestHelper {

    public typealias PreparedSavePress = ReadingListIngestor.PreparedSavePress

    /// What an Action Button save press produced, for the Provide Context /
    /// Save App Intents.
    public enum ActionButtonSaveOutcome {
        /// Save/send handled (or duplicate) AND verified present in the store.
        /// `savedURLString` is the URL that ended up saved — the item's CURRENT
        /// URL, so a wrapper resolved during ingest (apple.news → publisher) is
        /// already applied. Nil only when the outcome couldn't be determined
        /// before the timeout.
        case completed(savedURLString: String?)
        /// Double save with "ask every time" — the pending friend prompt is
        /// recorded; the intent should foreground the app so the friend
        /// selector can appear. `savedURLString` is the saved item's URL (the
        /// item exists before the prompt is answered).
        case friendPromptRequested(savedURLString: String)
        /// Double save whose configured action is a file export: the intent
        /// should build `item` in `format` (through the app shell's article
        /// exporter seam) and return it as its media.
        case exportRequested(item: ReadingListItem, format: ArticleExportFormat)
        /// Foreign-kind save (`SurfaceSupport`) — the item was DISCARDED. The
        /// intent throws an error dialog with the generic explanation.
        case unsupportedKind(owner: LunaApp)
        /// The press finished but left nothing usable behind. The intent throws;
        /// it must never report success over an empty or failed list.
        case saveFailed(IntentSaveVerification.Failure)
    }

    /// The user-facing dialog for an `unsupportedKind` save — used verbatim by
    /// the Save / Provide Context intents' thrown errors.
    public static func unsupportedDialogText(owner: LunaApp) -> String {
        SurfaceSupport.unsupportedMessage(owner: owner)
    }

    /// Handles a save press (save+ingest, double-press send, or ignore), giving
    /// up after `timeout` so the intent finishes promptly in the background, then
    /// verifies what the press left in the store. Work cut off by the timeout is
    /// persisted as pending/queued and retried later, and stays reported as
    /// handled — it IS in the app.
    ///
    /// `timeout` is the caller's runtime budget (`IntentSaveTimeout`): the intents
    /// pass the longer extended-runtime value where the system granted one, which
    /// is what lets a slow fetch failure be REPORTED rather than time out into a
    /// success.
    ///
    /// `doubleSaveActionSurface` is non-nil only where the configured
    /// double-save action is armed (Luna and Reader — the two apps that can
    /// build article files), mirroring the decision the Provide Context / Save
    /// intents make.
    public static func handleSavePress(
        urlString: String,
        doubleSaveActionSurface surface: String?,
        timeout: TimeInterval = IntentSaveTimeout.standard,
        attemptDate: Date = Date()
    ) async -> ActionButtonSaveOutcome {
        let pressedURLString = URLUnwrapper.ingestURL(from: urlString)?.absoluteString
            ?? urlString
        let result = await savePressRacingTimeout(
            urlString: urlString, doubleSaveActionSurface: surface, timeout: timeout,
            attemptDate: attemptDate)
        return verifiedOutcome(
            from: result, pressedURLString: pressedURLString,
            storedItem: currentStoreItem(for: result, pressedURLString: pressedURLString))
    }

    /// Freezes the atomic reservation + double-save decision before any network
    /// work begins. Provide Context serializes this value when it must hand the
    /// operation to SaveIntent, which prevents the resumed run from reserving a
    /// second press and changing the already-decided double-save semantics.
    public static func prepareSavePress(
        urlString: String,
        doubleSaveActionSurface surface: String?,
        attemptDate: Date = Date()
    ) -> PreparedSavePress? {
        ReadingListIngestor.shared.prepareSavePress(
            urlString: urlString, source: .appIntent,
            doubleSaveActionSurface: surface, attemptDate: attemptDate)
    }

    /// Performs one prepared state without a second reservation. The resumed
    /// LongRunning intent waits for a cancelled fast-path task to finish
    /// unwinding before it restarts the pending ingest.
    public static func performPreparedSavePress(
        _ prepared: PreparedSavePress,
        waitForCancelledFastPath: Bool = false
    ) async -> ActionButtonSaveOutcome {
        let result = await ReadingListIngestor.shared.performPreparedSavePress(
            prepared, waitForInFlight: waitForCancelledFastPath)
        return verifiedOutcome(
            from: result, pressedURLString: prepared.urlString,
            storedItem: currentStoreItem(
                for: result, pressedURLString: prepared.urlString))
    }

    /// Recommits the intent's URL-level timing marker at the end of every
    /// remaining handoff (document build, download, foreground continuation).
    /// `ReadingListIngestor` also finishes its own marker so a timed-out ingest
    /// that outlives the intent still advances to its true completion time.
    public static func finishSaveAttempt(
        urlString: String, at date: Date = Date()
    ) {
        guard let normalized = URLUnwrapper.ingestURL(from: urlString)?.absoluteString,
              let item = ReadingListStore.shared.item(forURLString: normalized)
        else { return }
        ReadingListStore.shared.finishSaveAttempt(for: item.id, at: date)
    }

    /// Re-reads the store for what the press actually left behind: by item id
    /// when the press produced one (the id survives an unwrap repoint, the URL
    /// doesn't), else by the pressed URL for a duplicate/ignored press.
    private static func currentStoreItem(
        for result: ReadingListIngestor.SavePressResult?, pressedURLString: String
    ) -> ReadingListItem? {
        guard let result else { return nil }
        if let item = result.item { return ReadingListStore.shared.item(withID: item.id) }
        return ReadingListStore.shared.item(forURLString: pressedURLString)
    }

    /// Turns the ingest result plus the item now IN THE STORE into the
    /// intent-facing outcome. Kept internal and store-free so unit tests can
    /// lock the mappings — most importantly that `.unsupportedKind` survives and
    /// that a missing or `.failed` item becomes `.saveFailed` instead of a
    /// success with nothing behind it.
    static func verifiedOutcome(
        from result: ReadingListIngestor.SavePressResult?,
        pressedURLString: String,
        storedItem: ReadingListItem?
    ) -> ActionButtonSaveOutcome {
        switch result {
        case nil:
            // The race expired: the ingest task continues and persists its
            // pending work, so there is nothing to verify and nothing wrong.
            return .completed(savedURLString: nil)
        case let .some(.unsupportedKind(owner)):
            return .unsupportedKind(owner: owner)
        case let .some(settled):
            guard let storedItem else {
                // The press produced an item that is no longer in the store: it
                // was DEDUPED into an existing save (a wrapper URL resolved to an
                // article already in the list, a store URL merged into an
                // existing price tracker), so the content IS in the app under
                // the surviving item. A gate-dropped save reports
                // `.unsupportedKind` above and never reaches here. A press that
                // produced no item at all (`.ignored` — an unusable URL, or a
                // duplicate whose item has since vanished) genuinely saved
                // nothing.
                guard settled.item != nil else { return .saveFailed(.nothingSaved) }
                return .completed(savedURLString: pressedURLString)
            }
            if let failure = IntentSaveVerification.failure(forState: storedItem.state) {
                return .saveFailed(failure)
            }
            if case .friendPromptRequested = settled {
                return .friendPromptRequested(savedURLString: storedItem.urlString)
            }
            if case let .exportRequested(_, format) = settled {
                // The STORED item, not the one the press carried: the export
                // reads content that only the verified copy is known to have.
                return .exportRequested(item: storedItem, format: format)
            }
            return .completed(savedURLString: storedItem.urlString)
        }
    }

    /// Runs `handleSavePress` raced against `timeout`; nil ⇒ timed out.
    private static func savePressRacingTimeout(
        urlString: String, doubleSaveActionSurface: String?, timeout: TimeInterval,
        attemptDate: Date
    ) async -> ReadingListIngestor.SavePressResult? {
        guard let url = URLUnwrapper.ingestURL(from: urlString) else { return .ignored }
        let urlString = url.absoluteString
        // NOT a task group: `withTaskGroup` awaits ALL children before returning,
        // and the save leg isn't reliably cancellation-responsive (web-archive
        // capture, image downloads), so a group blows through the budget.
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
                    doubleSaveActionSurface: doubleSaveActionSurface,
                    attemptDate: attemptDate)
                finish(result)
            }
            Task {
                try? await Task.sleep(
                    nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                finish(nil)
            }
        }
    }
}
