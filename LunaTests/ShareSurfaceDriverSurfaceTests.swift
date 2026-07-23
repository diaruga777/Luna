//
//  ShareSurfaceDriverSurfaceTests.swift
//  LunaTests
//

import LunaIngest
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import LunaShareSurface

/// The per-app content gate inside `ShareSurfaceDriver.present`
/// (`SurfaceSupport`, replacing the old cross-app-purchase `InteropGate`): an
/// unsupported cross-app save deletes the pending row (and any copied document
/// file) and presents `UnsupportedSaveViewController`; a same-app outcome and
/// `.failed` are byte-identical to today. Uses a fake host + scratch store —
/// same seams the driver was built around (the real `NSExtensionContext` has
/// none).
@MainActor
final class ShareSurfaceDriverSurfaceTests: XCTestCase {

    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ShareReaderViewController.Mode?
        var presented: [UIViewController] = []
        var confirmedSaved = 0
        var completedSilently = 0
        var autoDownloads: [String] = []
        var failures: [String] = []
        var openedURLs: [URL] = []

        func presentModally(_ viewController: UIViewController) { presented.append(viewController) }
        func confirmSavedThenComplete() { confirmedSaved += 1 }
        func completeSilently() { completedSilently += 1 }
        func autoDownloadThenComplete(urlString: String) { autoDownloads.append(urlString) }
        func failOrComplete(_ message: String) { failures.append(message) }
        func openURL(_ url: URL) { openedURLs.append(url) }
    }

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    private var host: FakeExtensionHost!

    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareSurfaceDriverSurfaceTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        host = FakeExtensionHost()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// A driver whose gate input (the running app) is pinned — no `Bundle.main` reads.
    private func makeDriver(current: LunaApp) -> ShareSurfaceDriver {
        // `process` keeps its default — these tests drive `present` directly,
        // so the pipeline closure is never invoked.
        ShareSurfaceDriver(
            host: host,
            store: store,
            surfaceDecision: { outcome in
                SurfaceSupport.evaluate(owner: outcome.owningApp, current: current)
            },
            currentApp: current)
    }

    /// A non-downloadable social URL (bluesky), so the share extension's
    /// non-textual flow takes its silent-terminal branch.
    private let socialURL = URL(string: "https://bsky.app/profile/someone/post/123")!

    // MARK: - Unsupported (cross-app, single-content app)

    func testUnsupportedSocialSaveDeletesPendingRowAndPresentsError() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        XCTAssertNil(store.item(forURLString: socialURL.absoluteString),
                     "an unsupported save must leave NOTHING in the store")
        XCTAssertEqual(host.presented.count, 1)
        let error = host.presented.first as? UnsupportedSaveViewController
        XCTAssertNotNil(error, "unsupported saves present the unsupported-kind error")
        XCTAssertEqual(host.confirmedSaved, 0, "never a 'Saved' checkmark for an unsupported save")
        XCTAssertEqual(host.autoDownloads, [])

        // Done on the error completes quietly.
        error?.onDone?()
        XCTAssertEqual(host.completedSilently, 1)
    }

    func testUnsupportedArticleDeletesRowBeforePersistingAnyContent() {
        let url = URL(string: "https://example.com/story")!
        _ = store.add(urlString: url.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .downloader)

        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: "Body text.", links: []),
        ])
        driver.present(.article(content, html: "<html></html>"), url: url)

        XCTAssertNil(store.item(forURLString: url.absoluteString))
        XCTAssertTrue(host.presented.first is UnsupportedSaveViewController)
        XCTAssertEqual(host.completedSilently, 0, "waits for the error card's Done")
    }

    func testUnsupportedDocumentDeletesRowAndCopiedSourceFile() {
        let item = ReadingListItem(
            seed: "doc", urlString: "lunadoc://ABC", title: "Report",
            dateAdded: Date(), state: .pending, documentType: "pdf",
            captureSource: .shareSheet)
        store.seedForTesting(items: [item], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.pdf")
        try? Data("pdf-bytes".utf8).write(to: sourceFile)

        let driver = makeDriver(current: .priceTracker)
        driver.present(.document(type: "pdf"), url: URL(string: "lunadoc://ABC")!)

        XCTAssertNil(store.item(forURLString: "lunadoc://ABC"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path),
                       "the copied document file must be cleaned up with the row")
        XCTAssertTrue(host.presented.first is UnsupportedSaveViewController)
    }

    func testUnsupportedResolvedWrapperDoesNotDeletePreexistingCanonicalItem() async {
        let wrapperURL = URL(string: "https://example.com/redirect?id=123")!
        let canonicalURL = URL(string: "https://bsky.app/profile/someone/post/123")!
        let existing = store.add(urlString: canonicalURL.absoluteString, source: .manual)
        _ = store.add(urlString: wrapperURL.absoluteString, source: .shareSheet)
        let driver = ShareSurfaceDriver(
            host: host,
            store: store,
            process: { _ in
                IngestResult(
                    url: canonicalURL,
                    outcome: .social(.bluesky, itemID: "123"))
            },
            surfaceDecision: { _ in
                .unsupported(owner: .downloader)
            },
            currentApp: .reader)

        await driver.ingestAndPresent(originalURL: wrapperURL)

        XCTAssertNil(store.item(forURLString: wrapperURL.absoluteString),
                     "wrapper placeholder is removed by canonical dedup")
        XCTAssertEqual(store.item(forURLString: canonicalURL.absoluteString)?.id, existing.id,
                       "unsupported cleanup must preserve the older canonical save")
        XCTAssertTrue(host.presented.first is UnsupportedSaveViewController)
    }

    // MARK: - Same-app outcome — byte-identical to today

    func testSameAppSaveIsUntouched() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .downloader)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        let saved = store.item(forURLString: socialURL.absoluteString)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.platform, .bluesky, "platform metadata persisted as today")
        XCTAssertEqual(host.autoDownloads, [socialURL.absoluteString],
                       "silent terminal exactly as today")
        XCTAssertTrue(host.presented.isEmpty, "no error card for a same-app save")
    }

    func testCentralLunaAppProcessesEveryKind() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .luna)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        XCTAssertNotNil(store.item(forURLString: socialURL.absoluteString))
        XCTAssertEqual(host.autoDownloads, [socialURL.absoluteString])
        XCTAssertTrue(host.presented.isEmpty)
    }

    // MARK: - .failed is never gated

    func testFailedOutcomeIsNeverGated() {
        let url = URL(string: "https://example.com/broken")!
        let item = store.add(urlString: url.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader)

        driver.present(.failed, url: url)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed, "marked failed as today")
        XCTAssertEqual(host.completedSilently, 1)
        XCTAssertTrue(host.presented.isEmpty)
    }
}
