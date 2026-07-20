//
//  ArchiveUnlockFlow.swift
//  Luna
//

import LunaModels
import LunaStorage
import UIKit

/// The shared archive-unlock presentation: wrap `articleURL` in an
/// `ArchiveWebReaderViewController`, wire its `onClose`/`onOpenInBrowser`/
/// `onExtracted` outcomes, and — on a successful extraction — dismiss and hand the
/// refreshed item to the caller. Every call site's own "what happens after unlock"
/// (reopen in a reader, reload a carousel card, rebuild a catch-up card) stays with
/// the caller via `onUnlocked`.
public enum ArchiveUnlockFlow {

    /// Presents the archive-unlock web reader for `item`, in its own navigation
    /// controller. Closing or opening in Safari just dismisses; a successful
    /// extraction dismisses and re-fetches `item` from `store` before calling
    /// `onUnlocked` — if the item has since vanished from the store, `onUnlocked`
    /// is not called.
    public static func present(
        item: ReadingListItem,
        articleURL: URL,
        store: ReadingListStore,
        from presenter: UIViewController,
        modalPresentationStyle: UIModalPresentationStyle = .automatic,
        onUnlocked: @escaping (ReadingListItem) -> Void
    ) {
        let reader = ArchiveWebReaderViewController(articleURL: articleURL, itemID: item.id, store: store)
        let nav = UINavigationController(rootViewController: reader)
        nav.modalPresentationStyle = modalPresentationStyle
        reader.onClose = { [weak nav] in
            guard let nav else { return }
            nav.dismiss(animated: true)
        }
        reader.onOpenInBrowser = { [weak nav] archiveURL in
            // This is an escape from archive.is's WKWebView-specific bot gate, so
            // it must leave Luna for the system browser — an SFSafari sheet remains
            // inside our presentation and doesn't provide the requested escape.
            guard let nav else { return }
            nav.dismiss(animated: true) {
                UIApplication.shared.open(archiveURL)
            }
        }
        reader.onExtracted = { [weak nav] in
            guard let nav else { return }
            nav.dismiss(animated: true) {
                guard let fresh = store.item(withID: item.id) else { return }
                onUnlocked(fresh)
            }
        }
        presenter.present(nav, animated: true)
    }
}
