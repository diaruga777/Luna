//
//  LiveMediaDownloadStartResult.swift
//  LunaMediaDownload
//

import Foundation

/// Why a `LiveMediaDownloadManager.startReportingResult` call did (or didn't)
/// begin a transfer.
///
/// The plain `start(...) -> Bool` API collapses every non-start into `false`,
/// which is fine for fire-and-forget callers but NOT for the App Intent media
/// handoff: a Shortcut that exits reporting success with nothing downloaded and
/// nothing queued is the exact silent failure the intents must surface. Only the
/// gate inside the manager knows which guard ended a start, so it reports the
/// reason here and `MediaIntentHandoff` decides which reasons are errors
/// (`.notAuthorized`, `.unsupported`, `.failed`) and which are legitimately
/// nothing to hand back (`.started`, `.alreadyDownloaded`, `.deferredUntilWiFi`).
public enum LiveMediaDownloadStartResult: Equatable {
    /// A transfer is running — either newly created or reattached to a live job.
    case started
    /// The media is already in the library; there was nothing to download.
    case alreadyDownloaded
    /// Held back by the user's own Wi-Fi-only setting; it will run on Wi-Fi.
    case deferredUntilWiFi
    /// Photos add-authorization was refused (sibling-app ownership only —
    /// Downloader-owned saves write to its own library and never ask).
    case notAuthorized
    /// Nothing downloadable could be resolved from this URL.
    case unsupported
    /// A genuine failure: no transfer exists and none will. `message` carries a
    /// user-facing explanation when the gate produced one (e.g. low storage).
    case failed(message: String?)

    /// Whether a transfer is now underway or the bytes are already on disk — the
    /// two outcomes a caller can treat as "the download is taken care of".
    public var isDownloadHandled: Bool {
        switch self {
        case .started, .alreadyDownloaded, .deferredUntilWiFi: return true
        case .notAuthorized, .unsupported, .failed: return false
        }
    }
}
