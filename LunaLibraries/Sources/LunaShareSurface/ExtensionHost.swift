//
//  ExtensionHost.swift
//  ShareKit
//

import LunaDesignSystem
import LunaIngest
import UIKit

/// What a hosted saved-media screen tells the surface that presented it: the user
/// has left it, by Done or by deleting the save.
///
/// The sender is a bare `UIViewController` (as `ReaderCompletionDelegate`'s is) so
/// this can sit here, below the media kind that owns the screen.
@MainActor
public protocol SavedMediaScreenDelegate: AnyObject {
    func savedMediaScreenDidFinish(_ screen: UIViewController)
}

/// What a hosted price editor tells the surface that presented it: the user pressed
/// its exit button. Here for the same reason `SavedMediaScreenDelegate` is. Nil in the
/// app, where the editor's own back chevron pops instead.
@MainActor
public protocol PriceEditorScreenDelegate: AnyObject {
    func priceEditorDidFinish(_ editor: UIViewController)
}

/// The host an extension surface ("share" zero-UI sheet or "action" Read-in-Luna
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
///
/// Every host is also the delegate of the three screens it puts up in its own chrome
/// — the drop card, the saved-media screen, the price editor — because leaving each of
/// them means the same thing to all hosts (see the defaults below). Declaring the
/// three refinements here is what lets a presenter hand a screen `host` directly
/// instead of an adapter per call site.
@MainActor
public protocol ExtensionHost: AnyObject, UnsupportedSaveCardDelegate,
    SavedMediaScreenDelegate, PriceEditorScreenDelegate {
    /// The reader mode the in-sheet reader should open in (action extension only);
    /// nil for the zero-UI share extension (no in-sheet UI at all). Drives the
    /// reader-vs-save-silently fork in the unified presenter. Kind-neutral
    /// (`ExtensionReaderMode`) — the article presenter maps it onto the actual
    /// reader's mode.
    var readerMode: ExtensionReaderMode? { get }

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

    /// Best-effort deep link into the containing app (`extensionContext.open`
    /// on the real host — extensions have no `UIApplication.shared`). Used by
    /// the rescue-failure card's "Finish in Luna" step; a silent failure is fine
    /// because the card always shows manual fallback instructions too.
    func openURL(_ url: URL)
}

public extension ExtensionHost {
    /// Nothing was saved, so the drop card's Done completes the request without
    /// a "Saved" checkmark — the same answer for every extension host.
    func unsupportedSaveCardDidFinish(_ card: UnsupportedSaveCardViewController) {
        completeSilently()
    }

    /// Leaving the saved-media screen completes SILENTLY rather than through the
    /// saved-checkmark chrome: that screen's own header already says "Saved to Luna",
    /// so the badge was a second confirmation card animating in over a screen the
    /// user had just dismissed. The same answer for every extension host.
    func savedMediaScreenDidFinish(_ screen: UIViewController) {
        completeSilently()
    }

    /// The price editor's exit DOES show the saved checkmark, unlike the media
    /// screen's: this editor has no header of its own claiming the save, so the
    /// checkmark is the only confirmation the user gets. The same answer for every
    /// extension host.
    func priceEditorDidFinish(_ editor: UIViewController) {
        confirmSavedThenComplete()
    }
}

