//
//  ReplayBugReporter.swift
//  ReaderKit
//

import LunaStorage
import LunaModels
import LunaTransitions
import UIKit

/// Shared "Report a bug" handling: marks the most recent terminated replay for an
/// item URL as `.userReported`, then presents a share sheet for its export zip.
/// Used by both the reading-list row context menu (main app) and the reader's
/// bug-report popover (reader stack, shared with the extensions).
public enum ReplayBugReporter {

    /// Marks the item's replay user-reported and shares its export zip from
    /// `presenter`. If no replay exists for the URL, shows a brief explanatory alert.
    /// `sourceView` anchors the popover on iPad. Safe to call from the main thread.
    public static func report(
        itemURLString: String,
        from presenter: UIViewController,
        sourceView: UIView,
        recorder: ReplayRecording = ReplayRecorder.shared
    ) {
        Task { [weak presenter, weak sourceView] in
            let zipURL = await recorder.markUserReported(forItemURLString: itemURLString)
            await MainActor.run {
                guard let presenter else { return }
                guard let zipURL, FileManager.default.fileExists(atPath: zipURL.path) else {
                    presentNoReplayAlert(from: presenter)
                    return
                }
                let activity = UIActivityViewController(
                    activityItems: [zipURL], applicationActivities: nil)
                activity.popoverPresentationController?.sourceView = sourceView ?? presenter.view
                presenter.present(activity, animated: true)
            }
        }
    }

    private static func presentNoReplayAlert(from presenter: UIViewController) {
        let alert = UIAlertController(
            title: "No Replay Found",
            message: "There's no diagnostic replay recorded for this save yet.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        DotMatrixModal.present(alert, from: presenter)
    }
}
