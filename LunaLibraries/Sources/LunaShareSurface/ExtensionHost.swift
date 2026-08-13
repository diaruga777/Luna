//
//  ExtensionHost.swift
//  ShareKit
//

import LunaDesignSystem
import LunaIngest
import UIKit

/// What a hosted saved-media screen tells the surface that presented it: the
/// user left it, either by Done or by deleting the save.
///
/// The sender is a bare `UIViewController`, the same as `ReaderCompletionDelegate`'s.
/// This lets the protocol sit here, below the media kind that owns the screen.
@MainActor
public protocol SavedMediaScreenDelegate: AnyObject {
    func savedMediaScreenDidFinish(_ screen: UIViewController)
}

/// What a hosted price editor tells the surface that presented it: the user
/// pressed its exit button. This mirrors `SavedMediaScreenDelegate` for the
/// same reason. It stays nil in the app, where the editor's own back chevron
/// pops instead.
@MainActor
public protocol PriceEditorScreenDelegate: AnyObject {
    func priceEditorDidFinish(_ editor: UIViewController)
}

/// The host an extension surface (the zero-UI "share" sheet or the "action"
/// Read-in-Luna sheet) provides to the shared `ShareSurfaceDriver`.
///
/// It abstracts the only parts of the real `NSExtensionContext`/UIKit harness
/// the ingest-and-present flow touches: completing the request, presenting a
/// view controller, and the surface's confirmation chrome. This lets the flow
/// run inside a UI-test or unit-test fixture with a fake host. The real
/// `NSExtensionContext` cannot be tested directly — a simulator cannot drive
/// the share sheet, and `completeRequest`/`inputItems` have no test seam.
///
/// `ShareViewController` is the real adapter, built on UIKit and
/// `NSExtensionContext`. A `FakeExtensionHost` in the tests records what the
/// driver asked for, so the whole "URL → pipeline → outcome → presentation"
/// flow can be asserted without UIKit or the network.
///
/// This protocol lives in ShareKit, compiled into both extension targets, and
/// depends only on UIKit and ReaderKit value types, so it stays extension-safe.
///
/// Every host is also the delegate of the three screens it puts up in its own
/// chrome: the drop card, the saved-media screen, and the price editor.
/// Leaving any of them means the same thing to all hosts (see the defaults
/// below). Declaring the three refinements here lets a presenter hand a
/// screen `host` directly, instead of building an adapter per call site.
@MainActor
public protocol ExtensionHost: AnyObject, UnsupportedSaveCardDelegate,
    SavedMediaScreenDelegate, PriceEditorScreenDelegate {
    /// The reader mode the in-sheet reader should open in. This is set only
    /// for the action extension; it stays nil for the zero-UI share
    /// extension, which has no in-sheet UI at all. It drives the
    /// reader-vs-save-silently fork in the unified presenter. The type
    /// (`ExtensionReaderMode`) is kind-neutral — the article presenter maps
    /// it onto the actual reader's mode.
    var readerMode: ExtensionReaderMode? { get }

    /// Presents `viewController` full-screen over the extension, wrapped in a
    /// navigation controller. Used for the in-sheet reader, the
    /// saved-non-textual screen, the price-tracking editor, and the
    /// archive-CAPTCHA reader.
    func presentModally(_ viewController: UIViewController)

    /// Shows the brief "Saved" checkmark, then completes the request. This is
    /// the terminal success affordance for an interactive extension surface.
    func confirmSavedThenComplete()

    /// Completes without showing extension UI. The zero-UI share extension
    /// uses this for ordinary articles, documents, and failures.
    func completeSilently()

    /// Saves silently while a media auto-download runs, then swaps to the
    /// "Saved" checkmark when it finishes and completes. Falls back to
    /// `confirmSavedThenComplete` when nothing is downloadable for
    /// `urlString`.
    func autoDownloadThenComplete(urlString: String)

    /// Surfaces `message` as visible error text on the action extension, or
    /// completes quietly on the share extension. Never shows a misleading
    /// "Saved" checkmark on a failure.
    func failOrComplete(_ message: String)

    /// Best-effort deep link into the containing app, through
    /// `extensionContext.open` on the real host (extensions have no
    /// `UIApplication.shared`). Used by the rescue-failure card's "Finish in
    /// Luna" step. A silent failure here is fine, because the card always
    /// shows manual fallback instructions too.
    func openURL(_ url: URL)
}

public extension ExtensionHost {
    /// Nothing was saved, so the drop card's Done completes the request
    /// without a "Saved" checkmark. Every extension host gives this same
    /// answer.
    func unsupportedSaveCardDidFinish(_ card: UnsupportedSaveCardViewController) {
        completeSilently()
    }

    /// Leaving the saved-media screen completes silently, not through the
    /// saved-checkmark chrome. That screen's own header already says "Saved
    /// to Luna", so the checkmark would be a second confirmation animating
    /// in over a screen the user just dismissed. Every extension host gives
    /// this same answer.
    func savedMediaScreenDidFinish(_ screen: UIViewController) {
        completeSilently()
    }

    /// The price editor's exit does show the saved checkmark, unlike the
    /// media screen's. This editor has no header of its own claiming the
    /// save, so the checkmark is the only confirmation the user gets. Every
    /// extension host gives this same answer.
    func priceEditorDidFinish(_ editor: UIViewController) {
        confirmSavedThenComplete()
    }
}

