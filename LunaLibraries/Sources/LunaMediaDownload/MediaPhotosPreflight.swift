//
//  MediaPhotosPreflight.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaURLClassification

/// Asks for Photos access BEFORE a long batch of downloads starts, rather than
/// at the moment one of them needs it.
///
/// The two download paths each prompt at a different, equally bad time during a
/// bulk import: a non-Downloader save asks for add-only access in the start gate
/// (`LiveMediaDownloadManager.gate`), and a Downloader save skips that and asks
/// for read/write when the FIRST transfer finishes
/// (`finishDownloaderStorage`) — which is a system alert landing over a progress
/// bar minutes into the run, with a queue of transfers already behind it that
/// fail as `.photosPermission` if the user is slow to answer.
///
/// Read/write is requested, not add-only, because it is the superset both paths
/// end up needing (resolving a saved asset back by its local identifier, and
/// deleting it) and because granting it also answers the add-only status — so
/// one prompt at the start replaces two mid-run.
public enum MediaPhotosPreflight {

    /// Requests Photos access if — and only if — this run could need it: finished
    /// downloads are set to land in Photos, and at least one candidate URL is
    /// something the media pipeline could actually download.
    ///
    /// Both conditions matter. Storage set to "Delete after …" keeps downloads in
    /// Luna and never touches Photos, and an import of nothing but articles
    /// through the central app must not open with a Photos prompt it will never
    /// use. The URL test is deliberately the PURE one (the platform table plus a
    /// direct-media path extension) — the same table ingestion classifies with,
    /// but with no network, because this runs before the first fetch.
    ///
    /// Returns whether Photos may now be written to. Callers ignore it: a refusal
    /// is not a reason to stop an import, it just means the media leg will report
    /// its own permission failures as it always has.
    @discardableResult
    public static func requestAccessIfNeeded(
        for urlStrings: [String],
        saver: PhotoLibrarySaving = PhotoLibrarySaver()
    ) async -> Bool {
        guard case .photos = MediaStorageSettings.option,
              urlStrings.contains(where: couldBeDownloadable)
        else { return false }
        // Itself a no-op once the status is determined — this only ever prompts on
        // the first import of a fresh install.
        return await saver.requestReadAuthorization()
    }

    /// Whether a URL could reach the download pipeline, decided from the URL
    /// alone: a recognized social platform, or a link that already names a media
    /// file.
    static func couldBeDownloadable(_ urlString: String) -> Bool {
        // Core asks after a plugin has actually declared a media asset.
        guard !URLBehaviorPolicy.pluginsOnly else { return false }
        return PlatformRecognizer.recognize(urlString) != nil
            || DirectMediaURL.kind(for: urlString) != nil
    }
}
