//
//  ArchiveUnlockFlow.swift
//  Luna
//

import LunaModels
import LunaStorage
import UIKit

/// The shared archive-unlock presentation: wrap `articleURL` in an
/// `ArchiveWebReaderViewController`, take its outcomes as its
/// `ArchiveUnlockDelegate`, and — on a successful extraction — dismiss and hand the
/// refreshed item to the caller. Every call site's own "what happens after unlock"
/// (reopen in a reader, reload a carousel card) stays with the caller via
/// `onUnlocked`.
public enum ArchiveUnlockFlow {

    /// Presents the archive-unlock web reader for `item`, in its own navigation
    /// controller. Closing or opening in Safari just dismisses; a successful
    /// extraction dismisses and re-fetches `item` from `store` before calling
    /// `onUnlocked` — if the item has since vanished from the store, `onUnlocked`
    /// is not called.
    public static func present(
        item: SavedItem,
        articleURL: URL,
        store: SavesStore,
        from presenter: UIViewController,
        modalPresentationStyle: UIModalPresentationStyle = .automatic,
        onUnlocked: @escaping (SavedItem) -> Void
    ) {
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id, store: store)
        let nav = UINavigationController(rootViewController: reader)
        nav.modalPresentationStyle = modalPresentationStyle
        reader.delegate = ModalUnlockLegs(
            nav: nav, itemID: item.id, store: store, onUnlocked: onUnlocked)
        presenter.present(nav, animated: true)
    }
}

/// The modal presentation's three legs, kept together for the life of the unlock.
///
/// A small coordinator rather than the flow itself: `ArchiveUnlockFlow` is an enum
/// with nothing to hold, while the unlock stays on screen until the user or the
/// CAPTCHA resolves it. The reader retains this; this holds the navigation controller
/// weakly, so nothing cycles — the same shape the three closures it replaces had.
@MainActor
private final class ModalUnlockLegs: ArchiveUnlockDelegate {
    private weak var nav: UINavigationController?
    private let itemID: UUID
    private let store: SavesStore
    private let onUnlocked: (SavedItem) -> Void

    /// `nonisolated` because `present` above is not: UIKit's own main-actor members
    /// reach it through the `@preconcurrency` import, but a fresh type of ours gets
    /// the real rule. Nothing here touches isolated state — it stores what it was
    /// handed.
    nonisolated init(
        nav: UINavigationController, itemID: UUID, store: SavesStore,
        onUnlocked: @escaping (SavedItem) -> Void
    ) {
        self.nav = nav
        self.itemID = itemID
        self.store = store
        self.onUnlocked = onUnlocked
    }

    func archiveReaderDidUnlockArticle(_ reader: ArchiveWebReaderViewController) {
        guard let nav else { return }
        nav.dismiss(animated: true) { [store, itemID, onUnlocked] in
            guard let fresh = store.item(withID: itemID) else { return }
            onUnlocked(fresh)
        }
    }

    func archiveReaderDidClose(_ reader: ArchiveWebReaderViewController) {
        guard let nav else { return }
        nav.dismiss(animated: true)
    }

    /// The main app is the one host that can leave Luna.
    var offersSystemBrowserEscape: Bool { true }

    func archiveReader(
        _ reader: ArchiveWebReaderViewController, openInSystemBrowser url: URL
    ) {
        // This is an escape from archive.is's WKWebView-specific bot gate, so
        // it must leave Luna for the system browser — an SFSafari sheet remains
        // inside our presentation and doesn't provide the requested escape.
        guard let nav else { return }
        nav.dismiss(animated: true) {
            UIApplication.shared.open(url)
        }
    }
}
