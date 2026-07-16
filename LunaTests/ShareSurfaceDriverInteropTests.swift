//
//  ShareSurfaceDriverInteropTests.swift
//  LunaTests
//

import LunaInterop
import LunaInteropUI
import LunaIngest
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import LunaShareSurface

/// The cross-app-interop gate inside `ShareSurfaceDriver.present`
/// (`claudedocs/interop-purchase.md`): a blocked cross-surface save deletes the
/// pending row (and any copied document file) and presents the interop prompt;
/// a paid save with the owning app missing saves as today and shows the install
/// note where the flow would otherwise end silently; same-surface saves and
/// `.failed` are byte-identical to today. Uses a fake host + scratch store —
/// same seams the driver was built around (the real `NSExtensionContext` has
/// none).
@MainActor
final class ShareSurfaceDriverInteropTests: XCTestCase {

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
            .appendingPathComponent("ShareSurfaceDriverInteropTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        host = FakeExtensionHost()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    /// A driver whose gate inputs are pinned — no App Group reads.
    private func makeDriver(
        current: InteropSurface, unlocked: Bool, ownerInstalled: Bool
    ) -> ShareSurfaceDriver {
        // `process` keeps its default — these tests drive `present` directly,
        // so the pipeline closure is never invoked.
        ShareSurfaceDriver(
            host: host,
            store: store,
            interopDecision: { outcome in
                InteropGate.evaluate(
                    owner: outcome.interopOwner, current: current,
                    isUnlocked: unlocked, isInstalled: { _ in ownerInstalled })
            },
            currentSurface: current)
    }

    /// A non-downloadable social URL (bluesky), so the share extension's
    /// non-textual flow takes its silent-terminal branch.
    private let socialURL = URL(string: "https://bsky.app/profile/someone/post/123")!

    // MARK: - Blocked (unpaid cross-surface)

    func testBlockedSocialSaveDeletesPendingRowAndPresentsPrompt() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader, unlocked: false, ownerInstalled: true)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        XCTAssertNil(store.item(forURLString: socialURL.absoluteString),
                     "a blocked save must leave NOTHING in the store")
        XCTAssertEqual(host.presented.count, 1)
        let prompt = host.presented.first as? InteropPromptViewController
        XCTAssertNotNil(prompt, "blocked saves present the interop prompt")
        XCTAssertEqual(host.confirmedSaved, 0, "never a 'Saved' checkmark for a blocked save")
        XCTAssertEqual(host.autoDownloads, [])

        // Done on the prompt completes quietly.
        prompt?.onDone?()
        XCTAssertEqual(host.completedSilently, 1)
    }

    func testBlockedArticleDeletesRowBeforePersistingAnyContent() {
        let url = URL(string: "https://example.com/story")!
        _ = store.add(urlString: url.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .downloader, unlocked: false, ownerInstalled: false)

        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: "Body text.", links: []),
        ])
        driver.present(.article(content, html: "<html></html>"), url: url)

        XCTAssertNil(store.item(forURLString: url.absoluteString))
        XCTAssertTrue(host.presented.first is InteropPromptViewController)
        XCTAssertEqual(host.completedSilently, 0, "waits for the prompt's Done")
    }

    func testBlockedDocumentDeletesRowAndCopiedSourceFile() {
        let item = ReadingListItem(
            seed: "doc", urlString: "lunadoc://ABC", title: "Report",
            dateAdded: Date(), state: .pending, documentType: "pdf",
            captureSource: .shareSheet)
        store.seedForTesting(items: [item], contents: [:])
        let sourceFile = store.articlesDirectory
            .appendingPathComponent("\(item.id.uuidString)-source.pdf")
        try? Data("pdf-bytes".utf8).write(to: sourceFile)

        let driver = makeDriver(current: .priceTracker, unlocked: false, ownerInstalled: false)
        driver.present(.document(type: "pdf"), url: URL(string: "lunadoc://ABC")!)

        XCTAssertNil(store.item(forURLString: "lunadoc://ABC"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path),
                       "the copied document file must be cleaned up with the row")
        XCTAssertTrue(host.presented.first is InteropPromptViewController)
    }

    func testBlockedResolvedWrapperDoesNotDeletePreexistingCanonicalItem() async {
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
            interopDecision: { _ in
                .blocked(owner: .downloader, ownerInstalled: true)
            },
            currentSurface: .reader)

        await driver.ingestAndPresent(originalURL: wrapperURL)

        XCTAssertNil(store.item(forURLString: wrapperURL.absoluteString),
                     "wrapper placeholder is removed by canonical dedup")
        XCTAssertEqual(store.item(forURLString: canonicalURL.absoluteString)?.id, existing.id,
                       "blocked cleanup must preserve the older canonical save")
        XCTAssertTrue(host.presented.first is InteropPromptViewController)
    }

    // MARK: - Same-surface / paid — byte-identical to today

    func testSameSurfaceUnpaidSaveIsUntouched() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .downloader, unlocked: false, ownerInstalled: false)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        let saved = store.item(forURLString: socialURL.absoluteString)
        XCTAssertNotNil(saved)
        XCTAssertEqual(saved?.platform, .bluesky, "platform metadata persisted as today")
        XCTAssertEqual(host.autoDownloads, [socialURL.absoluteString],
                       "silent terminal exactly as today")
        XCTAssertTrue(host.presented.isEmpty, "no prompt for a same-surface save")
    }

    func testCrossSurfacePaidWithOwnerInstalledIsUntouched() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader, unlocked: true, ownerInstalled: true)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        XCTAssertNotNil(store.item(forURLString: socialURL.absoluteString))
        XCTAssertEqual(host.autoDownloads, [socialURL.absoluteString])
        XCTAssertTrue(host.presented.isEmpty)
    }

    // MARK: - Paid, owner uninstalled — save proceeds + install note

    func testCrossSurfacePaidOwnerUninstalledSavesAndShowsInstallNote() {
        _ = store.add(urlString: socialURL.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader, unlocked: true, ownerInstalled: false)

        driver.present(.social(.bluesky, itemID: "123"), url: socialURL)

        let saved = store.item(forURLString: socialURL.absoluteString)
        XCTAssertNotNil(saved, "a paid cross-surface save always persists")
        XCTAssertEqual(saved?.platform, .bluesky)
        let prompt = host.presented.first as? InteropPromptViewController
        XCTAssertNotNil(prompt, "install note replaces the silent terminal")

        // Done on the install note confirms the (real) save.
        prompt?.onDone?()
        XCTAssertEqual(host.confirmedSaved, 1)
        XCTAssertEqual(host.completedSilently, 0)
    }

    func testPaidOwnerUninstalledArticleInShareExtensionShowsInstallNoteAfterPersisting() {
        let url = URL(string: "https://example.com/story")!
        _ = store.add(urlString: url.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .downloader, unlocked: true, ownerInstalled: false)

        let content = ArticleContent(title: "Story", blocks: [
            .init(kind: .paragraph, text: "Body text.", links: []),
        ])
        driver.present(.article(content, html: ""), url: url)

        XCTAssertNotNil(store.item(forURLString: url.absoluteString))
        XCTAssertTrue(host.presented.first is InteropPromptViewController)
        XCTAssertEqual(host.completedSilently, 0, "the prompt replaces completeSilently")
    }

    // MARK: - .failed is never gated

    func testFailedOutcomeIsNeverGated() {
        let url = URL(string: "https://example.com/broken")!
        let item = store.add(urlString: url.absoluteString, source: .shareSheet)
        let driver = makeDriver(current: .reader, unlocked: false, ownerInstalled: false)

        driver.present(.failed, url: url)

        XCTAssertEqual(store.item(withID: item.id)?.state, .failed, "marked failed as today")
        XCTAssertEqual(host.completedSilently, 1)
        XCTAssertTrue(host.presented.isEmpty)
    }
}
