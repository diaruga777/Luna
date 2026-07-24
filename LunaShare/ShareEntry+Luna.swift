//
//  ShareEntry+Luna.swift
//
//  The extension's principal class (Info.plist names the stable @objc name
//  `LunaShareEntry`). EXACTLY ONE variant is compiled into each host's
//  extension target (per-target membership exceptions on the shared folder),
//  registering the per-kind pipeline processors AND extension presenters that
//  host's app handles — the registries mirror the link set.
//

import LunaShareSurface
import UIKit
import LunaArticleIngest
import LunaHTMLClassification
import LunaIngest
import LunaMediaDownload
import LunaModels
import LunaPriceIngest
import LunaPriceUI
import LunaReaderUI
import LunaStorage

@objc(LunaShareEntry)
final class ShareEntry: ShareViewController {
    override init(nibName: String?, bundle: Bundle?) {
        IngestKindProcessors.article = ArticleIngestProcessor()
        IngestKindProcessors.product = ProductIngestProcessor()
        ShareKindPresenters.article = ArticlePresenterAdapter()
        ShareKindPresenters.media = MediaPresenterAdapter()
        ShareKindPresenters.product = ProductPresenterAdapter()
        super.init(nibName: nibName, bundle: bundle)
    }
    required init?(coder: NSCoder) { fatalError("not used") }
}

/// Adapts the protocol-free `ExtensionArticlePresenter` (LunaReaderUI) to
/// `ShareArticlePresenting` — the composition root is the one place allowed to
/// see the surface protocol and the kind module at once. Host side effects are
/// handed down as weak-host closures, matching the driver's lifetime rules.
private struct ArticlePresenterAdapter: ShareArticlePresenting {
    private let presenter = ExtensionArticlePresenter()

    func persistArticleExtras(
        item: ReadingListItem, content: ArticleContent, html: String, url: URL,
        store: ReadingListStore
    ) {
        presenter.persistArticleExtras(
            item: item, content: content, html: html, url: url, store: store)
    }

    func presentReader(url: URL, mode: ExtensionReaderMode, outcome: Outcome, host: ExtensionHost) {
        presenter.presentReader(
            url: url, mode: Self.readerMode(mode), outcome: outcome,
            onModeChange: { ActionReaderMode.last = Self.extensionMode($0) },
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    func presentArchive(url: URL, itemID: UUID, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentArchive(
            url: url, itemID: itemID, readerMode: host.readerMode.map(Self.readerMode),
            store: store,
            onModeChange: { ActionReaderMode.last = Self.extensionMode($0) },
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    /// `ExtensionReaderMode` (surface) ↔ `ShareReaderViewController.Mode`
    /// (article kind) share raw values by design.
    private static func readerMode(_ mode: ExtensionReaderMode) -> ShareReaderViewController.Mode {
        ShareReaderViewController.Mode(rawValue: mode.rawValue) ?? .reader
    }

    private static func extensionMode(_ mode: ShareReaderViewController.Mode) -> ExtensionReaderMode {
        ExtensionReaderMode(rawValue: mode.rawValue) ?? .reader
    }
}

/// Adapts the protocol-free `ExtensionMediaPresenter` (LunaMediaDownload) to
/// `ShareMediaPresenting`.
private struct MediaPresenterAdapter: ShareMediaPresenting {
    private let presenter = ExtensionMediaPresenter()

    func presentNonTextual(urlString: String, host: ExtensionHost) {
        presenter.presentNonTextual(
            urlString: urlString, interactive: host.readerMode != nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            confirmSavedThenComplete: { [weak host] in host?.confirmSavedThenComplete() },
            autoDownloadThenComplete: { [weak host] in host?.autoDownloadThenComplete(urlString: $0) })
    }

    func shouldAutoDownload(urlString: String) -> Bool {
        presenter.shouldAutoDownload(urlString: urlString)
    }

    func startAutoDownload(urlString: String) async {
        await presenter.startAutoDownload(urlString: urlString)
    }
}

/// Adapts the protocol-free `ExtensionProductPresenter` (LunaPriceUI) to
/// `ShareProductPresenting`.
private struct ProductPresenterAdapter: ShareProductPresenting {
    private let presenter = ExtensionProductPresenter()

    func presentPriceEditor(product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentPriceEditor(
            product: product, url: url, store: store,
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }
}
