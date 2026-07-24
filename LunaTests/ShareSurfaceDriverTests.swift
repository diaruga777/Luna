//
//  ShareSurfaceDriverTests.swift
//  LunaTests
//

import LunaShareSurface
import LunaMediaDownload
import LunaPriceUI
import LunaReaderUI
import LunaStorage
import LunaIngest
import LunaHTMLClassification
import LunaModels
import UIKit
import XCTest
@testable import Luna

/// Drives the host-agnostic `ShareSurfaceDriver` (the extracted share/action-extension
/// ingest+present flow) with a FAKE `ExtensionHost`, so the whole "Outcome →
/// persistence + presentation" flow is asserted without the untestable
/// `NSExtensionContext` harness. Locks in the bug-3 (price UI in the extension) and
/// bug-4 (a non-downloadable platform post via the share extension persists its
/// classification, not just a bare URL) unifications.
@MainActor
final class ShareSurfaceDriverTests: XCTestCase {

    /// Records everything the driver asked the host to do, so the per-surface
    /// presentation can be asserted in isolation.
    final class FakeExtensionHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?

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
        func openURL(_ url: URL) {}
    }

    private var scratch: URL!
    private var store: ReadingListStore!

    override func setUp() {
        super.setUp()
        // The driver reaches kind presentation through `ShareKindPresenters`;
        // register the production-shaped presenters explicitly (the test bundle
        // may hold its own framework copies, so no entry-class registration is
        // visible here).
        ShareKindPresenterTestSupport.registerAll()
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
    /// The surface gate is pinned to `.supported` — these tests exercise the per-
    /// outcome presentation/persistence logic, not the per-app content gate
    /// (see `ShareSurfaceDriverSurfaceTests` for that).
    private func makeDriver(isActionExtension: Bool) -> (ShareSurfaceDriver, FakeExtensionHost) {
        let host = FakeExtensionHost(isActionExtension: isActionExtension)
        let driver = ShareSurfaceDriver(host: host, store: store, surfaceDecision: { _ in .supported })
        return (driver, host)
    }

    private func sampleContent() -> ArticleContent {
        ArticleContent(title: "T", blocks: [.init(kind: .paragraph, text: "x", links: [])])
    }

    private func sampleProduct() -> ProductInfo {
        ProductInfo(name: "Widget", priceAmount: 42, priceCurrency: "USD",
                    imageURL: nil, brand: nil, productID: nil)
    }

    // MARK: - Bug 4: a non-downloadable platform post via the share extension
    // persists its classification

    /// The zero-UI share extension, given a `.social` outcome for a platform
    /// `MediaDownloadablePlatform` doesn't support (Bluesky), must PERSIST the
    /// classification (platform + item id) to the shared store — not drop it to a
    /// bare URL the main app has to re-classify. Before the fix, a non-downloadable
    /// post routed straight to auto-download and saved only the plain URL.
    func testShareExtensionPersistsNonDownloadablePlatformClassification() {
        let urlString = "https://bsky.app/profile/someone/post/123"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.social(.bluesky, itemID: "123"), url: url(urlString))

        let saved = store.item(forURLString: urlString)
        XCTAssertEqual(saved?.platform, .bluesky,
                       "the share extension must persist the platform classification")
        XCTAssertEqual(saved?.platformItemID, "123")
        XCTAssertEqual(saved?.state, .ready, "a classified post is a complete save")
        XCTAssertEqual(host.autoDownloadedURL, urlString,
                       "a non-downloadable platform still takes the (no-op) auto-download/confirm path")
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

    /// TikTok is a video platform but is not a social post. Its identity must
    /// survive extension presentation so it receives the download UI.
    func testShareExtensionPresentsDownloadUIForTikTokVideo() {
        let urlString = "https://www.tiktok.com/@u/video/7212345678901234567"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: false)

        driver.present(.video(.tiktok, itemID: "7212345678901234567"), url: url(urlString))

        XCTAssertEqual(store.item(forURLString: urlString)?.contentPlatform, .tiktok)
        XCTAssertTrue(host.presented.first is SavedNonTextualViewController)
        XCTAssertNil(host.autoDownloadedURL)
    }

    /// YouTube is not a special extension embed/poster case. It follows the same
    /// shared video outcome into the extension's normal media playback controls.
    func testBothExtensionsPresentStandardDownloadUIForYouTubeVideo() {
        let urlString = "https://youtu.be/dQw4w9WgXcQ?t=30"

        for isActionExtension in [false, true] {
            if let existing = store.item(forURLString: urlString) {
                store.delete(existing)
            }
            _ = store.add(urlString: urlString)
            let (driver, host) = makeDriver(isActionExtension: isActionExtension)

            driver.present(
                .video(.youtube, itemID: "dQw4w9WgXcQ"),
                url: url(urlString))

            let saved = store.item(forURLString: urlString)
            XCTAssertEqual(saved?.contentPlatform, .youtube)
            XCTAssertEqual(saved?.platformItemID, "dQw4w9WgXcQ")
            XCTAssertTrue(host.presented.first is SavedNonTextualViewController)
            XCTAssertFalse(host.presented.contains { $0 is ShareReaderViewController })
            XCTAssertNil(host.autoDownloadedURL)
        }
    }

    /// The action extension shows the saved-non-textual screen for a video (the reader
    /// VC must never see a video) AND persists the classification.
    func testActionExtensionVideoShowsSavedNonTextualAndPersists() {
        let urlString = "https://www.tiktok.com/@u/video/7212345678901234567"
        _ = store.add(urlString: urlString)
        let (driver, host) = makeDriver(isActionExtension: true)

        driver.present(.video(.tiktok, itemID: "7212345678901234567"), url: url(urlString))

        XCTAssertTrue(host.presented.first is SavedNonTextualViewController,
                      "action ext shows the saved-non-textual screen for a video")
        XCTAssertFalse(host.presented.contains { $0 is ShareReaderViewController },
                       "a video must NEVER reach the article reader")
        XCTAssertEqual(store.item(forURLString: urlString)?.platformItemID, "7212345678901234567")
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

    func testGoogleShoppingProductPersistsSellerURLsAsTrackerStores() {
        let googleURL = url("https://www.google.com/search?q=mova+v50+complete+vs+ultr&udm=28&shopmd=1")
        _ = store.add(urlString: googleURL.absoluteString)
        let (driver, host) = makeDriver(isActionExtension: false)
        let product = ProductInfo(
            name: "Mova V50 Ultra Robotic Vacuum and Mop",
            priceAmount: 1098,
            priceCurrency: "AUD",
            imageURL: nil,
            brand: nil,
            productID: nil,
            sellers: [
                ProductSellerInfo(
                    url: url("https://www.amazon.com.au/MOVA-V50-Ultra-Auto-Empty-Robot/dp/B0F1234567"),
                    price: ProductPrice(amount: 1099, currency: "AUD")),
                ProductSellerInfo(
                    url: url("https://www.harveynorman.com.au/mova-v50-ultra-robotic-vacuum-and-mop.html"),
                    price: ProductPrice(amount: 1098, currency: "AUD")),
                ProductSellerInfo(
                    url: url("https://au.mova-tech.com/products/mova-v50-ultra-robot-vacuum"),
                    price: ProductPrice(amount: 1099, currency: "AUD")),
            ])

        driver.present(.product(product, html: "<html></html>"), url: googleURL)

        XCTAssertTrue(host.presented.first is PriceTrackingViewController)
        let tracker = store.items().first?.priceTracker
        XCTAssertEqual(tracker?.stores.map(\.urlString), [
            "https://www.amazon.com.au/MOVA-V50-Ultra-Auto-Empty-Robot/dp/B0F1234567",
            "https://www.harveynorman.com.au/mova-v50-ultra-robotic-vacuum-and-mop.html",
            "https://au.mova-tech.com/products/mova-v50-ultra-robot-vacuum",
        ])
        XCTAssertEqual(tracker?.stores.map(\.lastPrice), [1099, 1098, 1099])
        XCTAssertEqual(tracker?.initialPrice, 1098)
        XCTAssertFalse(tracker?.stores.contains { $0.urlString.contains("google.com") } ?? true)
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

    /// `.failed` now presents the URL-rescue hand-off card in the action extension
    /// (never a misleading "Saved") and completes without UI in the share extension
    /// — both marking the item failed for retry. (See `claudedocs/url-rescue.md`;
    /// the dedicated `ShareSurfaceDriverRescueTests` assert the card details.)
    func testFailedPresentsRescueCardInActionAndQuietCompleteInShare() {
        let urlString = "https://example.com/dead"

        _ = store.add(urlString: urlString)
        let (actionDriver, actionHost) = makeDriver(isActionExtension: true)
        actionDriver.present(.failed, url: url(urlString))
        XCTAssertTrue(actionHost.presented.contains { $0 is RescueFailureViewController },
                      "action ext presents the rescue hand-off card on failure")
        XCTAssertFalse(actionHost.confirmedSaved, "never a misleading Saved on failure")
        XCTAssertEqual(store.item(forURLString: urlString)?.state, .failed)

        store.delete(store.item(forURLString: urlString)!)
        _ = store.add(urlString: urlString)
        let (shareDriver, shareHost) = makeDriver(isActionExtension: false)
        shareDriver.present(.failed, url: url(urlString))
        XCTAssertTrue(shareHost.completedSilently)
        XCTAssertFalse(shareHost.confirmedSaved)
        XCTAssertEqual(store.item(forURLString: urlString)?.state, .failed)
    }
}
