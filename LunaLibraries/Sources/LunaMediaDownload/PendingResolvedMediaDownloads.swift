//
//  PendingResolvedMediaDownloads.swift
//  LunaMediaDownload
//

import Foundation
import LunaStorage
import LunaURLClassification
import UIKit

/// Drains what Safari's in-page player queued.
///
/// The extension resolved the post itself (the same `SocialMediaResolver` this
/// module re-exports), so there is nothing left to resolve: the assets go
/// straight into the download manager's already-resolved entry point, which is
/// the same one URL Rescue uses.
///
/// Lives here rather than in the app shell because it names media symbols: the
/// two media `KindWiring`s call it, and the apps that link no media module have
/// no drain at all (their `resolvedmedia` deep link is a no-op, which is the
/// correct behavior — nothing can write that queue for them either).
public enum PendingResolvedMediaDownloads {

    /// Takes every queued record and starts its download. `returningToSource`
    /// carries the deep link's `ret=safari` flag: once at least one download is
    /// under way, hand the user back to the page they were watching — the same
    /// bounce a media pill save does, through the same policy.
    public static func drain(returningToSource: Bool = false) {
        let records = PendingResolvedMediaStore.shared.takeAll()
        guard !records.isEmpty else { return }
        Task { @MainActor in
            var started = false
            for record in records {
                let didStart = await LiveMediaDownloadManager.shared.startWithResolvedAssets(
                    sourceURLString: record.sourceURLString, title: record.title,
                    assets: record.assets)
                started = started || didStart
            }
            guard SafariReturnPolicy.shouldReturn(
                outcome: started ? .handled : .failedOrUnsupported,
                kind: .media, flagged: returningToSource),
                let last = records.last,
                let sourceURL = URL(string: last.sourceURLString) else { return }
            await UIApplication.shared.open(sourceURL)
        }
    }
}
