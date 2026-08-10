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
                // the media card and the reading-list row are the same item
                // rather than two orphans.
                let urlString = persistSave(for: record)
                let result = await LiveMediaDownloadManager.shared.startResultWithResolvedAssets(
                    sourceURLString: urlString, title: record.title, assets: record.assets)
                handledSomething = handledSomething || result.reportsItsOwnOutcome
            }
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
    }

    /// Reserves this post's reading-list row and returns the URL the save is
    /// keyed under. Reserving is the synchronous half of an ordinary save press
    /// (`ReadingListIngestor.prepareSavePress` does the same thing), and leaves
    /// the row `.pending` — the next launch/foreground `ingestAllPending` sweep
    /// finishes its metadata, and finds the transfer already running rather than
    /// starting a second one.
    @MainActor
    private static func persistSave(for record: ResolvedMediaRecord) -> String {
        let urlString = URLUnwrapper.ingestURL(from: record.sourceURLString)?.absoluteString
            ?? record.sourceURLString
        _ = ReadingListStore.shared.reserveSaveAttempt(urlString: urlString, at: Date())
        return urlString
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
