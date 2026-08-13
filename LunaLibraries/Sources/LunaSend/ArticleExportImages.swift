//
//  ArticleExportImages.swift
//  Luna
//

import Foundation
import LunaModels

/// Fetches the article images an export needs and that aren't on disk yet.
///
/// The one conformer wraps LunaReaderUI's `ArticleImageDownloader`, which this
/// module cannot see; it is installed on `ArticleExportImages.preparer` by the
/// app's `KindWiring`.
public protocol ArticleExportImagePreparing {
    /// Returns `content` with the previously-missing images' `imageFileName`s
    /// filled in. Returning `content` unchanged means nothing was fetchable.
    func preparedContent(
        _ content: ArticleContent, for item: ReadingListItem
    ) async -> ArticleContent
}

/// The seam that lets an export FETCH the article images that aren't on disk
/// yet, instead of shipping whatever a reader happened to have downloaded.
///
/// This matters because content is persisted before its pictures are: an article
/// becomes `.ready` once its text is extracted and only its unknown-size
/// top-of-page images have landed, with the rest downloading in a detached task
/// afterwards — and a save through the share/action extension, a paste, or a
/// mail import downloads none at all. An export taken in that window (a double
/// save fires within SEVEN SECONDS of the save) used to come out with no images
/// whatsoever. `ArticleImageFiles` finds anything already local; this closes the
/// rest of the gap.
///
/// The downloader lives in LunaReaderUI, which this module can't see, so the app
/// installs a witness from its `KindWiring` — the one place allowed to see
/// both tiers. Extensions leave it nil and export from local files only.
public enum ArticleExportImages {

    /// Downloads any of the article's images that aren't local yet and returns
    /// the content with `imageFileName` filled in. Installed by the app's
    /// `KindWiring`; nil in extensions.
    public static var preparer: ArticleExportImagePreparing?

    /// How long an export waits for missing images before building anyway.
    ///
    /// Bounded because this runs in front of a share sheet and inside an App
    /// Intent's budget. Work cut off here is not wasted: the downloader writes
    /// each file as it finishes, so a later export (or reader open) resolves
    /// them through `ArticleImageFiles` without fetching again.
    public static let preparationTimeout: TimeInterval = 15

    /// Runs `preparer` bounded by `preparationTimeout`. Returns nil when there
    /// is nothing to do — no seam, or every image already local — so the caller
    /// can skip re-persisting identical content.
    static func prepared(
        _ content: ArticleContent, for item: ReadingListItem, imagesDirectory: URL
    ) async -> ArticleContent? {
        guard let preparer,
              ArticleImageFiles.hasUnresolvedImages(in: content, directory: imagesDirectory)
        else { return nil }

        let prepared = await withTimeout(preparationTimeout) {
            await preparer.preparedContent(content, for: item)
        }
        guard let prepared, prepared.blocks != content.blocks else { return nil }
        return prepared
    }

    /// Races `work` against a sleep; nil ⇒ the deadline won. The work task keeps
    /// running (its downloads still land on disk) — this only stops the caller
    /// from waiting on it.
    private static func withTimeout<T: Sendable>(
        _ seconds: TimeInterval, _ work: @escaping @Sendable () async -> T
    ) async -> T? {
        let resumeLatch = OneShotLatch()
        return await withCheckedContinuation { continuation in
            @Sendable func finish(_ value: T?) {
                if resumeLatch.claim() { continuation.resume(returning: value) }
            }
            Task { finish(await work()) }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
                finish(nil)
            }
        }
    }
}
