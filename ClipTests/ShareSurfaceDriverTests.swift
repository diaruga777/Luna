//
//  ShareSurfaceDriverTests.swift
//  ClipTests
//

import ClipStorage
import ClipIngest
import ClipHTMLClassification
import ClipModels
import UIKit
import XCTest
@testable import Clip

/// Drives the host-agnostic `ShareSurfaceDriver` (the extracted share/action-extension
/// ingest+present flow) with a FAKE `ExtensionHost`, so the whole "Outcome →
/// persistence + presentation" flow is asserted without the untestable
/// `NSExtensionContext` harness. Locks in the bug-3 (price UI in the extension) and
/// bug-4 (YouTube via share extension persists its classification) unifications.
@MainActor
final class ShareSurfaceDriverTests: XCTestCase {

    /// Records everything the driver asked the host to do, so the per-surface
    /// presentation can be asserted in isolation.
    final class FakeExtensionHost: ExtensionHost {
        var readerMode: ShareReaderViewController.Mode?

        private(set) var presented: [UIViewController] = []
        private(set) var confirmedSaved = false
        private(set) var completedSilently = false
        private(set) var autoDownloadedURL: String?
        private(set) var error: String?

        init(isActionExtension: Bool) {
            // Mirrors `ShareViewController.readerMode`: action ext opens a reader, the
            // zero-UI share ext saves silently (nil).
            self.readerMode = isActionExtension ? .reader : nil
        }

        func presentModally(_ viewController: UIViewController) { presented.append(viewController) }
        func confirmSavedThenComplete() { confirmedSaved = true }
        func completeSilently() { completedSilently = true }
        func autoDownloadThenComplete(urlString: String) { autoDownloadedURL = urlString }
        func failOrComplete(_ message: String) { error = message }
    }

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShareSurfaceDriver-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: scratch)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratch)
        super.tearDown()
    }

    private func url(_ string: String) -> URL {
        guard let url = URL(string: string) else { fatalError("bad test URL: \(string)") }
        return url
    }

    /// Seeds an item for `urlString` and returns the driver + host wired to the test
    /// store (no live pipeline — `present` is called directly with a fixed Outcome).
    private func makeDriver(isActionExtension: Bool) -> (ShareSurfaceDriver, FakeExtensionHost) {
        let host = FakeExtensionHost(isActionExtension: isActionExtension)
        let driver = ShareSurfaceDriver(host: host, store: store)
        return (driver, host)
    }

    private func sampleContent() -> ArticleContent {
        ArticleContent(title: "T", blocks: [.init(kind: .paragraph, text: "x", links: [])])
    }

    private func sampleProduct() -> ProductInfo {
        ProductInfo(name: "Widget", priceAmount: 42, priceCurrency: "USD",
                    imageURL: nil, brand: nil, productID: nil)
    }

    // MARK: - Bug 4: YouTube via the share extension persists its classification

    /// The zero-UI share extension, given a `.video(.youtube)` outcome, must PERSIST the
    /// YouTube classification (platform + videoID) to the shared store — not drop it to
    /// a bare URL the main app has to re-classify. Before the fix the share extension
    /// routed `.video` straight to auto-download and saved only the plain URL.
    func testShareExtensionPersistsYouTubeVideoClassification() {
        let urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.video(.youtube, itemID: "dQw4w9WgXcQ"), url: url(urlString))

        let saved = store.item(forURLString: urlString)
        XCTAssertEqual(saved?.youtubeVideoID, "dQw4w9WgXcQ",
                       "the share extension must persist the YouTube video id")
        XCTAssertEqual(saved?.contentPlatform, .youtube)
        XCTAssertEqual(saved?.state, .ready, "a classified video is a complete save")
        XCTAssertEqual(host.autoDownloadedURL, urlString,
                       "YouTube still takes the (no-op) auto-download/confirm path")
    }

    /// A downloadable social post in the share extension persists its platform +
    /// item id and opens the same explicit media-download UI as the action extension.
    func testShareExtensionPresentsDownloadUIForSocialMedia() {
        let urlString = "https://x.com/jack/status/20"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.social(.x, itemID: "20"), url: url(urlString))

        let saved = store.item(forURLString: urlString)
        XCTAssertEqual(saved?.contentPlatform, .x)
        XCTAssertEqual(saved?.platformItemID, "20")
        XCTAssertTrue(host.presented.first is SavedNonTextualViewController)
        XCTAssertNil(host.autoDownloadedURL)
    }

    /// TikTok is a video platform but is not a YouTube player. Its identity must
    /// survive extension presentation so it receives the social media UI.
    func testShareExtensionPresentsDownloadUIForTikTokVideo() {
        let urlString = "https://www.tiktok.com/@u/video/7212345678901234567"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.video(.tiktok, itemID: "7212345678901234567"), url: url(urlString))

        XCTAssertEqual(store.item(forURLString: urlString)?.contentPlatform, .tiktok)
        XCTAssertTrue(host.presented.first is SavedNonTextualViewController)
        XCTAssertNil(host.autoDownloadedURL)
    }

    /// The action extension shows the saved-non-textual screen for a video (the reader
    /// VC must never see a video) AND persists the classification.
    func testActionExtensionVideoShowsSavedNonTextualAndPersists() {
        let urlString = "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: true)

        driver.present(.video(.youtube, itemID: "dQw4w9WgXcQ"), url: url(urlString))

        XCTAssertTrue(host.presented.first is SavedNonTextualViewController,
                      "action ext shows the saved-non-textual screen for a video")
        XCTAssertFalse(host.presented.contains { $0 is ShareReaderViewController },
                       "a video must NEVER reach the article reader")
        XCTAssertEqual(store.item(forURLString: urlString)?.youtubeVideoID, "dQw4w9WgXcQ")
    }

    // MARK: - Bug 3: the action extension presents the price-tracking UI

    /// A `.product` outcome must PRESENT the same price-tracking editor the main app
    /// shows (within the extension host), not just save silently. The tracker is
    /// persisted and the editor is presented.
    func testActionExtensionProductPresentsPriceEditor() {
        let urlString = "https://www.amazon.com/dp/B0ACME1234"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: true)

        driver.present(.product(sampleProduct(), html: "<html></html>"), url: url(urlString))

        XCTAssertTrue(host.presented.first is PriceTrackingViewController,
                      "the extension must present the price-tracking editor for a product")
        XCTAssertNotNil(store.item(forURLString: urlString)?.priceTracker,
                        "the tracker is persisted before presenting the editor")
    }

    /// The zero-UI share extension ALSO presents the price editor (same unified flow).
    func testShareExtensionProductPresentsPriceEditor() {
        let urlString = "https://www.amazon.com/dp/B0ACME1234"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.product(sampleProduct(), html: "<html></html>"), url: url(urlString))

        XCTAssertTrue(host.presented.first is PriceTrackingViewController)
        XCTAssertNotNil(store.item(forURLString: urlString)?.priceTracker)
    }

    // MARK: - Article / failure parity

    /// The action extension presents the in-sheet reader for an article and persists
    /// the content; the share extension completes with no UI.
    func testArticlePresentationDiffersByHostButPersistsBoth() {
        let urlString = "https://example.com/story"

        _ = store.add(urlString: urlString)
        let (actionDriver, actionHost) = makeDriver(isActionExtension: true)
        actionDriver.present(.article(sampleContent(), html: "<html></html>"), url: url(urlString))
        XCTAssertTrue(actionHost.presented.first is ShareReaderViewController,
                      "action ext opens the in-sheet reader for an article")

        // Fresh store item for the share-extension leg.
        store.delete(store.item(forURLString: urlString)!)
        _ = store.add(urlString: urlString)
        let (shareDriver, shareHost) = makeDriver(isActionExtension: false)
        shareDriver.present(.article(sampleContent(), html: "<html></html>"), url: url(urlString))
        XCTAssertTrue(shareHost.completedSilently, "share ext must show no UI for an article")
        XCTAssertFalse(shareHost.confirmedSaved)
        XCTAssertTrue(shareHost.presented.isEmpty)
    }

    /// `.failed` shows an error in the action extension and completes without UI in
    /// the share extension (marking the item failed for retry).
    func testFailedSurfacesErrorInActionAndQuietCompleteInShare() {
        let urlString = "https://example.com/dead"

        _ = store.add(urlString: urlString)
        let (actionDriver, actionHost) = makeDriver(isActionExtension: true)
        actionDriver.present(.failed, url: url(urlString))
        XCTAssertNotNil(actionHost.error, "action ext surfaces an error on failure")
        XCTAssertFalse(actionHost.confirmedSaved, "never a misleading Saved on failure")

        store.delete(store.item(forURLString: urlString)!)
        _ = store.add(urlString: urlString)
        let (shareDriver, shareHost) = makeDriver(isActionExtension: false)
        shareDriver.present(.failed, url: url(urlString))
        XCTAssertTrue(shareHost.completedSilently)
        XCTAssertFalse(shareHost.confirmedSaved)
        XCTAssertEqual(store.item(forURLString: urlString)?.state, .failed)
    }
}
