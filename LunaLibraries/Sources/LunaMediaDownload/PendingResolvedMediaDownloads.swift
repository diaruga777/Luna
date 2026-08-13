//
//  PendingResolvedMediaDownloads.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaStorage
import LunaURLClassification
import UIKit

enum PendingResolvedMediaReturnPolicy {
    /// The page a drain is about — either because the deep link that triggered
    /// it said so, or because the appex stamped a fresh return marker beside the
    /// assets when the user pressed Download.
    ///
    /// A lifecycle drain (`deepLinkFlagged: false`) does not ACT on this: it
    /// remembers it for the deep link that has not landed yet (see
    /// `rememberReturn`). Sending a user to Safari because a marker is fresh
    /// would also fire on a manual launch from the Home Screen a few seconds
    /// after a Download tap — the one launch nobody asked to leave.
    static func sourceURLString(
        records: [ResolvedMediaRecord], deepLinkFlagged: Bool, now: Date
    ) -> String? {
        if let freshMarkedRecord = records.last(where: {
            ($0.returnToSourceUntil ?? .distantPast) > now
        }) {
            return freshMarkedRecord.sourceURLString
        }
        return deepLinkFlagged ? records.last?.sourceURLString : nil
    }
}

/// Drains what Safari's in-page player queued.
///
/// The extension resolved the post itself (the same `SocialMediaResolver` this
/// module re-exports), so there is nothing left to resolve: the assets go
/// straight into the download manager's already-resolved entry point, which is
/// the same one URL Rescue uses.
///
/// The whole point of the app being launched at all is what it does here and
/// nothing else — **persist the save, start the transfer, request the Live
/// Activity, leave**. ActivityKit only shows an activity the APP's process
/// requested, and a Safari extension cannot request one, which is why a hand-off
/// exists rather than the appex simply downloading. Everything after that is the
/// background `URLSession`'s and the Live Activity's job, so the app hands the
/// user back to the page they were watching instead of showing them a deck they
/// did not ask for.
///
/// Lives here rather than in the app shell because it names media symbols: the
/// two media `KindWiring`s call it, and the apps that link no media module have
/// no drain at all (their `resolvedmedia` deep link is a no-op, which is the
/// correct behavior — nothing can write that queue for them either).
public enum PendingResolvedMediaDownloads {

    /// What a lifecycle drain (launch / foreground) took out of the queue before
    /// the `ret=safari` deep link could be delivered, and until when it is worth
    /// acting on. Process-local on purpose: the race it covers is between two
    /// entry points of the SAME launch.
    private static let rememberedLock = NSLock()
    private static var rememberedReturn: (urlString: String, until: Date)?

    /// Takes every queued record and starts its download. `returningToSource`
    /// carries the deep link's `ret=safari` flag: this drain is the one the user
    /// asked for by pressing Download, so once the work is handed off it hands
    /// the user back to the page they were watching — the same bounce a media
    /// pill save does, through the same policy.
    public static func drain(returningToSource: Bool = false) {
        let records = PendingResolvedMediaStore.shared.takeAll()
        guard !records.isEmpty else {
            // Launch/foreground recovery can win the race with `openURLContexts`
            // and empty the queue first. The deep link still arrives, and the
            // bounce is ITS to make — with the URL that earlier drain remembered.
            guard returningToSource, let urlString = takeRememberedReturn(now: Date())
            else { return }
            Task { @MainActor in await returnToSource(urlString: urlString) }
            return
        }
        Task { @MainActor in
            var handledSomething = false
            for record in records {
                // The save is persisted BEFORE anything that can fail or take
                // time: it is what survives when the user never comes back to
                // this app. The row also gives the download job its identity, so
                // the media card and the save row are the same item
                // rather than two orphans.
                let urlString = persistSave(for: record)
                let result = await LiveMediaDownloadManager.shared.startResultWithResolvedAssets(
                    sourceURLString: urlString, title: record.title, assets: record.assets)
                handledSomething = handledSomething || result.reportsItsOwnOutcome
            }
            await handOffToSourceIfNeeded(
                records: records, returningToSource: returningToSource,
                handledSomething: handledSomething)
            // Whatever the records could not answer for themselves is still
            // owed. The user is already on their way back to Safari, so it runs
            // HERE, under a background lease, rather than waiting for someone to
            // open the app again (`BackgroundIngestCompletion` in
            // LunaSaves — this module cannot name it, and does not need
            // to; an empty queue makes this a no-op).
            PendingIngestCompletions.shared.requestRun()
        }
    }

    /// The bounce, unchanged and unconditional-looking on purpose: it is its own
    /// method so its several "no return from here" exits cannot also skip the
    /// ingest request that follows it.
    @MainActor
    private static func handOffToSourceIfNeeded(
        records: [ResolvedMediaRecord], returningToSource: Bool, handledSomething: Bool
    ) async {
        let returnURLString = PendingResolvedMediaReturnPolicy.sourceURLString(
            records: records, deepLinkFlagged: returningToSource, now: Date())
        guard let returnURLString else { return }
        guard returningToSource else {
            rememberReturn(
                urlString: returnURLString,
                until: records.compactMap(\.returnToSourceUntil).max() ?? Date())
            return
        }
        // A failure has a Live Activity of its own to report itself with, so
        // it is not a reason to strand the user in an app whose UI says
        // nothing about this download. Only a drain that produced NOTHING at
        // all (no job, no activity) keeps them here.
        guard SafariReturnPolicy.shouldReturn(
            outcome: handledSomething ? .handled : .failedOrUnsupported,
            kind: .media, flagged: true) else { return }
        await returnToSource(urlString: returnURLString)
    }

    /// Reserves this post's save row and returns the URL the save is
    /// keyed under. Reserving is the synchronous half of an ordinary save press
    /// (`SavesIngestor.prepareSavePress` does the same thing), and leaves
    /// the row `.pending`.
    ///
    /// The other half — the metadata that gives the row its title and kind — is
    /// OWED here, durably, in the same breath as the reservation, and
    /// then paid immediately from the hand-off itself whenever the record
    /// carries it (`completeFromHandoff`). The debt is written first, and
    /// before the transfer starts, for the same reason the reservation is:
    /// nothing that can fail or take time may stand between the press and the
    /// recoverable state. What the record could NOT carry stays owed and the
    /// background ingest finishes it (`BackgroundIngestCompletion`), which also
    /// finds the transfer already running rather than starting a second one.
    ///
    /// The two stores are parameters so a test can exercise this against its own
    /// (a `.shared` saves list and a `.shared` debt queue both live in the App
    /// Group, which the whole test run shares — a fixture that writes there is a
    /// fixture every later suite inherits).
    @MainActor
    static func persistSave(
        for record: ResolvedMediaRecord,
        store: SavesStore = .shared,
        completions: PendingIngestCompletions = .shared
    ) -> String {
        let urlString = URLUnwrapper.ingestURL(from: record.sourceURLString)?.absoluteString
            ?? record.sourceURLString
        let reservation = store.reserveSaveAttempt(urlString: urlString, at: Date())
        completions.owe(itemID: reservation.item.id, urlString: urlString)
        completeFromHandoff(
            record, urlString: urlString, itemID: reservation.item.id,
            store: store, completions: completions)
        return urlString
    }

    /// Finishes the row from what the EXTENSION already knew, without a network
    /// round trip.
    ///
    /// The appex had to resolve this post to render the in-page player, and it
    /// queued what it learned along with the assets — so the app re-fetching the
    /// same metadata would be paying twice for one answer and delaying the row
    /// (and the deck) behind a request it did not need. This writes exactly the
    /// row a metadata pass would (`PlatformItemIngestor` → `savePlatformMetadata`)
    /// and settles the debt.
    ///
    /// Two conditions, and a record failing either is simply left owed:
    ///
    ///  - **A title.** It is the one metadata field the extension actually has
    ///    (the page's own, sent with the resolve request). No title means an
    ///    incomplete hand-off — the resolve had not finished, or the page had
    ///    none — which is precisely the case the background ingest exists for.
    ///  - **A recognized platform.** `PlatformRecognizer` is pure URL parsing,
    ///    so this costs nothing, but a URL no rule recognizes has no `platform`/
    ///    `platformItemID` to write and must go through the classifying pipeline.
    ///
    /// It is safe to skip that pipeline HERE, and only here: a queued record
    /// always carries playable assets (`PendingResolvedMediaStore.append`
    /// refuses an assetless one), so this URL is a video post — the media kind —
    /// and not, say, one of the long-form X posts that read as articles.
    ///
    /// The row THUMBNAIL is the one field still only a fetch could add, and the
    /// download fetches that poster for its own card anyway
    /// (`fetchAndPublishThumbnail`) — see `claudedocs/safari-extension.md`.
    @MainActor
    @discardableResult
    static func completeFromHandoff(
        _ record: ResolvedMediaRecord, urlString: String, itemID: UUID,
        store: SavesStore = .shared,
        completions: PendingIngestCompletions = .shared
    ) -> Bool {
        let title = record.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !title.isEmpty, let recognized = PlatformRecognizer.recognize(urlString),
              store.savePlatformMetadata(
                platform: recognized.platform, platformItemID: recognized.itemID,
                title: title, thumbnailFileName: nil, for: itemID) != nil
        else { return false }
        completions.settle(itemID)
        SharedDiagnosticLog.record(
            "resolved-media: completed \(urlString) from the hand-off — no metadata fetch",
            category: "media-download")
        return true
    }

    /// Back to Safari, at the page the user was actually on — never the
    /// canonicalized save URL. iOS has no "return to the previous app" API, so
    /// this is an ordinary `open` of the https URL: the default browser comes
    /// forward showing that page (typically in a new tab — see
    /// `claudedocs/safari-extension.md`).
    @MainActor
    private static func returnToSource(urlString: String) async {
        guard let url = URL(string: urlString), url.scheme?.hasPrefix("http") == true
        else { return }
        let opened = await UIApplication.shared.open(url)
        if !opened {
            SharedDiagnosticLog.record(
                "resolved-media return to Safari refused for \(urlString)",
                category: "media-download")
        }
    }

    private static func rememberReturn(urlString: String, until: Date) {
        rememberedLock.lock()
        rememberedReturn = (urlString, until)
        rememberedLock.unlock()
    }

    private static func takeRememberedReturn(now: Date) -> String? {
        rememberedLock.lock()
        defer { rememberedLock.unlock() }
        guard let remembered = rememberedReturn, remembered.until > now else { return nil }
        rememberedReturn = nil
        return remembered.urlString
    }
}

extension LiveMediaDownloadStartResult {
    /// Whether this outcome is one the user will be TOLD about outside the app —
    /// a running transfer, bytes already on disk, a Wi-Fi deferral, or a failure
    /// that posted its own Live Activity. All of those make leaving the app the
    /// right move; only an outcome with no surface anywhere keeps the user here.
    var reportsItsOwnOutcome: Bool {
        switch self {
        case .started, .alreadyDownloaded, .deferredUntilWiFi, .notAuthorized: return true
        case .failed(let message): return message != nil
        case .unsupported: return false
        }
    }
}
