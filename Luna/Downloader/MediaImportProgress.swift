//
//  MediaImportProgress.swift
//  Luna
//
//  The media-kind body of the bulk import's download watcher. Compiled only
//  into media-handling app targets (Downloader and the central Luna app), and
//  excluded from the others through the synchronized group's membership
//  exceptions. Their `KindWiring` variants install it as part of
//  `LinkImportRunner.media`. In an article- or product-only app, that leg
//  stays nil, which is correct there: a media link cannot pass those apps'
//  content gate, so no transfer ever exists to watch. See
//  `claudedocs/import-export.md`.
//

import LunaMediaDownload
import LunaSaves

enum MediaImportProgress {

    /// The live state of the transfer for `urlString`, or nil when there is none.
    ///
    /// `isFinished` is read from the job's phase rather than from `progress`
    /// reaching 1: a failed transfer stops short and a saving one sits at 1
    /// for a moment, so a fraction alone would either strand the import's
    /// slice open until its deadline or close it before the file was
    /// durable. `@Sendable` because the runner polls it from its own task,
    /// off the main thread; the manager's job store is internally locked,
    /// which is why every other background caller reads it the same way.
    @Sendable
    static func observe(urlString: String) -> LinkImportRunner.MediaDownloadState? {
        guard let snapshot = LiveMediaDownloadManager.shared.currentDownloadSnapshot(
            forSourceURLString: urlString)
        else { return nil }
        let isFinished: Bool
        switch snapshot.phase {
        case .finished, .failed:
            isFinished = true
        case .resolving, .downloading, .waiting, .suspended, .saving:
            // `suspended` and `waiting` are still live: a Wi-Fi-only deferral or a
            // grace-period suspension resumes on its own, and the import's own
            // deadline is what eventually lets it go rather than a wrong verdict
            // here.
            isFinished = false
        }
        return LinkImportRunner.MediaDownloadState(
            fraction: snapshot.progress,
            receivedByteCount: snapshot.receivedByteCount,
            isFinished: isFinished)
    }
}
