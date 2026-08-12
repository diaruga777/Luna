//
//  MediaSaveFailureRecording.swift
//  LunaMediaDownload
//

import Foundation
import LunaModels
import LunaStorage

/// The ONE writer of `SaveFailureReason.noMediaFound`.
///
/// A media save is the odd one out: the pipeline classifies the post
/// successfully (`.video` / `.social`), the row is stored, and only the download
/// that follows discovers there is nothing playable behind the link. So the
/// reading-list item never enters `.failed` — by design, since a recognized
/// platform item still renders from a logo and a deep link — and the failure
/// reason had, until now, no writer at all. `URLRescueWiring.failureKind` reads
/// exactly this reason to choose `RescueRequest.FailureKind.mediaNoAssets`, a
/// branch that could therefore never be taken.
enum MediaSaveFailureRecording {

    /// Files "no downloadable asset" against whichever reading-list item owns
    /// `sourceURLString`, and puts the same sentence in the save's trace.
    ///
    /// Two very different callers reach this. Inside a save's task tree (the
    /// awaited auto-download) a recorder is bound, so marking it terminal keeps
    /// the whole buffered trace instead of letting the ingestor drop it as the
    /// success the `Outcome` claims. From a background transfer (the Live
    /// Activity job, which fails minutes later in a delegate callback) there is
    /// no task tree left, so the one line is appended to the item's trace file
    /// directly — `SaveDiagnostics.formatLine` exists for exactly that.
    static func recordNoMedia(sourceURLString: String, detail: String) {
        let message = "media: no downloadable asset — \(detail)"
        guard let item = ReadingListStore.shared.item(forURLString: sourceURLString) else {
            SaveDiagnostics.record(message, category: "media")
            return
        }
        SaveFailureStore.shared.recordFailure(item.id, reason: .noMediaFound)
        if SaveDiagnostics.isRecording {
            SaveDiagnostics.record(message, category: "media")
            SaveDiagnostics.markTerminalFailure(.noMediaFound)
        } else {
            SaveDiagnosticsStore.shared.appendLine(
                SaveDiagnostics.formatLine(message, category: "media"), for: item.id)
        }
    }
}
