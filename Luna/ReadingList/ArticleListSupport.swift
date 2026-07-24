//
//  ArticleListSupport.swift
//  Luna
//
//  Article-kind implementation of `ArticleListSupporting` — compiled only into
//  article-handling app targets (Reader + the central Luna app; excluded from
//  the others via the synchronized group's membership exceptions) and installed
//  by their `KindWiring` variants.
//

import LunaArchiveReader
import LunaDesignSystem
import LunaModels
import LunaReaderUI
import LunaReadingList
import LunaSend
import LunaStorage
import LunaTransitions
import UIKit

struct ArticleListSupport: ArticleListSupporting {

    var isKindleConfigured: Bool {
        ArticleSendCoordinator.shared.isConfigured(destinationID: ArticleDestinationID.kindle)
    }

    var showsReadingTime: Bool { ReaderSettings.showReadingTime }
    var showsReadingProgress: Bool { ReaderSettings.showReadingProgress }

    func openArticle(
        _ item: ReadingListItem, content: ArticleContent,
        presenter: UIViewController, transitionSourceView: UIView?
    ) {
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared)
        if let transitionSourceView {
            LunarEclipseTransitionCenter.prepare(reader: reader, sourceView: transitionSourceView)
        }
        presenter.navigationController?.pushViewController(reader, animated: true)
    }

    /// Presents the interactive WKWebView archive reader for a `.needsCaptcha` item.
    /// On a successful extraction it dismisses and hands the now-`.ready` item back;
    /// an "Open in Safari" button hands off to real Safari when the embedded web
    /// view can't clear archive.today's Cloudflare gate.
    func presentArchiveUnlock(
        item: ReadingListItem, articleURL: URL, presenter: UIViewController,
        onReady: @escaping (ReadingListItem, UIViewController) -> Void
    ) {
        ArchiveUnlockFlow.present(
            item: item, articleURL: articleURL, store: .shared, from: presenter
        ) { [weak presenter] fresh in
            guard let presenter else { return }
            // Archive/direct-unlock extraction happens in LunaArchiveReader, below
            // the thumbnail helper's module, so it saves text first and lets the app
            // process backfill the row cover. Without this nudge, the cover appears
            // only on the next launch/foreground backfill pass.
            ReadingListIngestor.shared.backfillMissingThumbnails()
            onReady(fresh, presenter)   // now .ready → native reader
        }
    }

    func openTransientArticle(
        item: ReadingListItem, content: ArticleContent, on nav: UINavigationController?
    ) {
        let reader = ReaderHostFactory.make(
            item: item, content: content,
            shareProvider: AppReaderShareProvider.shared)
        nav?.pushViewController(reader, animated: true)
    }

    func sendToKindle(_ item: ReadingListItem) {
        Task { await ArticleSendCoordinator.shared.send(item, toDestinationID: ArticleDestinationID.kindle) }
    }

    /// Builds the article's EPUB off-main and presents the system share sheet so
    /// the user can send it to another app or save it to Files.
    func shareEbook(_ item: ReadingListItem, from presenter: UIViewController, sourceView: UIView) {
        ArticleExportService().presentShareSheet(for: item, from: presenter, sourceView: sourceView)
    }

    func retryPendingSends() {
        ArticleSendCoordinator.shared.retryPendingSends()
    }
}
