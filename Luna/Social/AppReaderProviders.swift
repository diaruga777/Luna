//
//  AppReaderProviders.swift
//  Luna
//

import LunaSocialUI
import LunaSaves
import LunaModels
import LunaDesignSystem
import LunaReaderUI
import LunaSend
import LunaStorage
import UIKit

/// Main-app sharing provider: pick recipients and send a Luna email (via
/// `SendToFriendSheet` → `EmailShareCenter`), or export/share the link. Injected
/// into readers in the main app; the share extension passes nil instead.
public final class AppReaderShareProvider: ReaderShareProviding {
    public static let shared = AppReaderShareProvider()

    public var providesShareMenu: Bool { true }

    public func shareMenu(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> UIMenu? {
        let rows = rows(
            urlString: urlString, title: title, from: presenter, sourceView: sourceView)
        guard !rows.isEmpty else { return nil }
        return ReaderShareSheet.menu(rows: rows)
    }

    public func presentShareSheet(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) {
        let rows = rows(
            urlString: urlString, title: title, from: presenter, sourceView: sourceView)
        guard !rows.isEmpty else { return }
        ReaderShareSheet.present(
            from: presenter, rows: rows,
            title: SavedItem.isWebPageURL(urlString)
                ? L10n.string("Common_share") : ReaderShareSheet.exportTitle)
    }

    /// The one option list behind both the menu and the fallback sheet. Imported
    /// emails/documents offer formats directly because their synthetic URL cannot
    /// be shared. Menu-primary buttons need these rows too: an empty menu does not
    /// invoke the button's tap fallback.
    private func rows(
        urlString: String, title: String?, from presenter: UIViewController, sourceView: UIView
    ) -> [ReaderShareSheet.Row] {
        let item = SavesStore.shared.item(forURLString: urlString)
        // File export is for readable articles/documents only — never media posts,
        // and only once the text is actually extracted: a pending, failed or
        // still-locked save has nothing any format could carry, so offering the
        // formats there would lead to a "Couldn't Export Article" alert every
        // time. `state` is the cheap signal — reading the content back to check
        // would decode the whole article just to build a menu.
        let isArticle = item.map { !$0.isPlatformItem } ?? false
        let onExport: (ArticleExportFormat) -> Void = { [weak presenter] format in
            guard let presenter, let item else { return }
            ArticleExportService().presentShareSheet(
                format, for: item, from: presenter, sourceView: sourceView)
        }
        if let item, isArticle, !item.isShareable {
            guard item.state == .ready else { return [] }
            return ReaderShareSheet.exportRows(onExport: onExport)
        }
        return ReaderShareSheet.rows(
            includeExport: isArticle && item?.state == .ready,
            ereaderRows: ereaderRows(for: item, isArticle: isArticle, from: presenter),
            onPickFriend: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.present(
                    from: presenter, item: item,
                    urlString: urlString, title: title)
            },
            onShareLink: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.shareLink(
                    urlString: urlString, from: presenter, sourceView: sourceView)
            },
            onCopyLink: { [weak presenter] in
                guard let presenter else { return }
                SendToFriendSheet.copyLink(urlString: urlString, from: presenter)
            },
            onExport: onExport)
    }

    /// One "Send to …" row per configured ereader destination, for ready
    /// articles only — the same gate as file export, since both need the
    /// extracted content.
    private func ereaderRows(
        for item: SavedItem?, isArticle: Bool, from presenter: UIViewController
    ) -> [ReaderShareSheet.Row] {
        guard let item, isArticle, item.state == .ready else { return [] }
        // Gives the rendezvous a chance to be live before the row below reads
        // `isRendezvousActive` for its dot.
        XteinkBLECentral.shared.beginRendezvousScan()
        return ArticleSendCoordinator.shared.configuredDestinations().map { destination in
            let isXteink = destination.id == ArticleDestinationID.xteink
            return .action(
                title: L10n.string(
                    "Sharing_readerShareSheet_sendToDestination", destination.displayName),
                systemImage: isXteink ? "books.vertical" : "book.closed",
                statusDotColor: isXteink
                    ? (XteinkBLECentral.shared.isRendezvousActive ? .systemGreen : .tertiaryLabel)
                    : nil
            ) { [weak presenter] in
                // Xteink is enqueue-only: the device collects queued sends only
                // when the reader opens a sync window, so there is nothing to
                // await here — confirm the queue and stop.
                guard !isXteink else {
                    if let presenter {
                        LunaToast.show(
                            L10n.string("Sharing_readerShareSheet_xteinkQueuedToast"),
                            from: presenter)
                    }
                    Task { await ArticleSendCoordinator.shared.send(item, toDestinationID: destination.id) }
                    return
                }
                Task { @MainActor in
                    await ArticleSendCoordinator.shared.send(item, toDestinationID: destination.id)
                    guard let presenter,
                          let updated = SavesStore.shared.item(withID: item.id),
                          updated.sendState(for: destination.id) == .queued
                    else { return }
                    // Still queued: the receiver wasn't reachable. Say when it
                    // will actually go out, so the silence reads as "later",
                    // not "broken".
                    let alert = UIAlertController(
                        title: L10n.string(
                            "Sharing_readerShareSheet_sendQueuedTitle", destination.displayName),
                        message: L10n.string("Sharing_readerShareSheet_sendQueuedGenericMessage"),
                        preferredStyle: .alert)
                    alert.addAction(UIAlertAction(title: L10n.string("Common_ok"), style: .default))
                    presenter.present(alert, animated: true)
                }
            }
        }
            + ReaderShareSheet.pluginRows(forSaveID: item.id, kind: .article)
    }

    public func saveLink(urlString: String) {
        Task { await SavesIngestor.shared.handleSavePress(urlString: urlString) }
    }
}
