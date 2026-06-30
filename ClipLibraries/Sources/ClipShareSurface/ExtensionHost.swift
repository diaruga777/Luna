//
//  ExtensionHost.swift
//  ShareKit
//

import ClipIngest
import UIKit

/// The host an extension surface ("share" zero-UI sheet or "action" Read-in-Quartz
/// sheet) provides to the shared `ShareSurfaceDriver`. It abstracts the ONLY parts
/// of the real `NSExtensionContext`/UIKit harness the ingest+present flow touches —
/// completing the request, presenting a view controller, and the surface's
/// confirmation chrome — so the flow can run inside a UITest/unit FIXTURE with a
/// fake host (the real `NSExtensionContext` is untestable: a simulator can't drive
/// the share sheet, and `completeRequest`/`inputItems` have no test seam).
///
/// `ShareViewController` is the real adapter (UIKit + `NSExtensionContext`); a
/// `FakeExtensionHost` in the tests records what the driver asked for, so the whole
/// "URL → pipeline → Outcome → presentation" flow is asserted without UIKit/network.
///
/// Extension-safe: lives in ShareKit (compiled into both extension targets), depends
/// only on UIKit + ReaderKit value types.
@MainActor
public protocol ExtensionHost: AnyObject {
    /// The reader mode the in-sheet reader should open in (action extension only);
    /// nil for the zero-UI share extension (no in-sheet UI at all). Drives the
    /// reader-vs-save-silently fork in the unified presenter.
    var readerMode: ShareReaderViewController.Mode? { get }

    /// Presents `viewController` full-screen over the extension (wrapping it in a nav
    /// controller). Used for the in-sheet reader, the saved-non-textual screen, the
    /// price-tracking editor, and the archive-CAPTCHA reader.
    func presentModally(_ viewController: UIViewController)

    /// Shows the brief "Saved" checkmark, then completes the request. The terminal
    /// success affordance for an interactive extension surface.
    func confirmSavedThenComplete()

    /// Completes without showing extension UI. The zero-UI share extension uses
    /// this for ordinary articles, documents, and failures.
    func completeSilently()

    /// Saves silently while a media auto-download runs, swapping to the "Saved"
    /// checkmark when it finishes, then completes. Falls back to `confirmSavedThenComplete`
    /// when nothing is downloadable for `urlString`.
    func autoDownloadThenComplete(urlString: String)

    /// Surfaces `message` as visible error text (action extension) or completes
    /// quietly (share extension) — NEVER a misleading "Saved" checkmark on a failure.
    func failOrComplete(_ message: String)
}
