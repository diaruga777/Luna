//
//  ShareKindPresenterTestSupport.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaIngest
import LunaMediaDownload
import LunaModels
import LunaPriceUI
import LunaReaderUI
import LunaShareSurface
import LunaStorage
import UIKit

/// Registers the SAME per-kind extension presenters the central Luna
/// extension's entry class (`ShareEntry+Luna`) registers, so driver tests can
/// exercise every `Outcome` branch. Registered explicitly in each test class's
/// `setUp` — like the pipeline processors in `SurfaceParityTests` — because
/// the test bundle may hold its own copies of the frameworks, so no app-launch
/// registration is guaranteed to be visible through the registry here.
@MainActor
enum ShareKindPresenterTestSupport {
    static func registerAll() {
        ShareKindPresenters.article = ArticlePresenterAdapter()
        ShareKindPresenters.media = MediaPresenterAdapter()
        ShareKindPresenters.product = ProductPresenterAdapter()
    }
}

// The adapters below mirror the production composition roots (`ShareEntry+*` /
// `ActionEntry+*`), so what the driver presents in tests is exactly what the
// extensions present. The one deviation: `onModeChange` is nil so tests never
// write the action extension's persisted `ActionReaderMode` preference.

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
            onModeChange: nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    func presentArchive(url: URL, itemID: UUID, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentArchive(
            url: url, itemID: itemID, readerMode: host.readerMode.map(Self.readerMode),
            store: store,
            onModeChange: nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }

    private static func readerMode(_ mode: ExtensionReaderMode) -> ShareReaderViewController.Mode {
        ShareReaderViewController.Mode(rawValue: mode.rawValue) ?? .reader
    }
}

private struct MediaPresenterAdapter: ShareMediaPresenting {
    private let presenter = ExtensionMediaPresenter()

    func presentNonTextual(urlString: String, host: ExtensionHost) {
        presenter.presentNonTextual(
            urlString: urlString, interactive: host.readerMode != nil,
            presentModally: { [weak host] in host?.presentModally($0) },
            completeOnExit: { [weak host] in host?.completeSilently() },
            autoDownloadThenComplete: { [weak host] in host?.autoDownloadThenComplete(urlString: $0) })
    }

    func shouldAutoDownload(urlString: String) -> Bool {
        presenter.shouldAutoDownload(urlString: urlString)
    }

    func startAutoDownload(urlString: String) async {
        await presenter.startAutoDownload(urlString: urlString)
    }
}

private struct ProductPresenterAdapter: ShareProductPresenting {
    private let presenter = ExtensionProductPresenter()

    func presentPriceEditor(product: ProductInfo, url: URL, store: ReadingListStore, host: ExtensionHost) {
        presenter.presentPriceEditor(
            product: product, url: url, store: store,
            showLoadingPhase: { [weak host] in host?.showLoadingPhase($0) },
            presentModally: { [weak host] in host?.presentModally($0) },
            complete: { [weak host] in host?.confirmSavedThenComplete() })
    }
}
