//
//  ExtensionProductPresenterTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaShareSurface
import LunaStorage
@testable import LunaPriceUI
import UIKit
import XCTest

/// The extension's immediate-editor path. A share-sheet save of an
/// already-tracked product must merge into the existing tracker through
/// `ProductTrackerMerge`, even when both pages declare the same GTIN, rather
/// than create a second tracker for the same product. These pin the merge
/// outcome at the presenter's own level: the placeholder item is removed,
/// the existing tracker gains the store, and no duplicate tracker is left
/// behind.
@MainActor
final class ExtensionProductPresenterTests: XCTestCase {

    /// A minimal `ExtensionHost` fake recording what the presenter asked for —
    /// same shape as `ShareSurfaceDriverTests.FakeExtensionHost`, kept local
    /// since that one is private to its own file.
    private final class FakeExtensionHost: ExtensionHost {
        var readerMode: ExtensionReaderMode?
        private(set) var presented: [UIViewController] = []
        private(set) var confirmedSaved = false

        func presentModally(_ viewController: UIViewController) { presented.append(viewController) }
        func confirmSavedThenComplete() { confirmedSaved = true }
        func completeSilently() {}
        func autoDownloadThenComplete(urlString: String) {}
        func failOrComplete(_ message: String) {}
        func openURL(_ url: URL) {}
    }

    private var tempDirectory: URL!
    private var snapshotDirectory: URL?
    private var store: SavesStore!
    private var presenter: ExtensionProductPresenter!

    override func setUp() {
        super.setUp()
        SellerComparisonRunner.installed = nil
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionProductPresenterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: tempDirectory)
        presenter = ExtensionProductPresenter()
        presenter.snapshotStore = .temporary(directory: &snapshotDirectory)
        presenter.artworkLoader = StubArtworkLoader(data: nil)
    }

    override func tearDown() {
        SellerComparisonRunner.installed = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        if let snapshotDirectory { try? FileManager.default.removeItem(at: snapshotDirectory) }
        super.tearDown()
    }

    private func product(name: String, gtin: String? = nil, brand: String? = "Hisense") -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: 1999, priceCurrency: "AUD", imageURL: nil, brand: brand,
            productID: gtin, identifiers: ProductIdentifiers(gtin: gtin, brand: brand))
    }

    /// `presentModally` is called SYNCHRONOUSLY on both outcomes
    /// (`presentPriceEditor` never awaits anything itself); `confirmSavedThenComplete`
    /// is the EDITOR's own Done callback (`editor.onDone`), fired only when the
    /// user finishes with it — never during this call — except on the early
    /// failure path (no placeholder item), which calls it directly.
    private func present(product: ProductInfo, url: URL) -> [UIViewController] {
        let host = FakeExtensionHost()
        presenter.presentPriceEditor(product: product, url: url, store: store, host: host)
        return host.presented
    }

    // MARK: - No match: creates a new tracker

    func testNoExistingTrackerCreatesANewTrackerAndPresentsTheEditor() {
        let url = URL(string: "https://a.example/p/1")!
        _ = store.add(urlString: url.absoluteString)
        let presented = present(product: product(name: "Widget"), url: url)

        XCTAssertTrue(presented.first is PriceTrackingViewController)
        XCTAssertNotNil(store.item(forURLString: url.absoluteString)?.priceTracker)
    }

    func testNewTrackerPersistsDeclaredProductArtwork() async throws {
        let url = URL(string: "https://www.amazon.com.au/acme/dp/B0ACME1234")!
        let imageURL = URL(string: "https://m.media-amazon.com/images/I/acme.jpg")!
        let loaded = expectation(description: "artwork loader")
        let loader = StubArtworkLoader(data: Data("amazon-artwork".utf8))
        loader.onLoad = { loaded.fulfill() }
        presenter.artworkLoader = loader
        _ = store.add(urlString: url.absoluteString)
        _ = present(
            product: ProductInfo(
                name: "Acme", priceAmount: 42, priceCurrency: "AUD",
                imageURL: imageURL, brand: nil, productID: "B0ACME1234",
                identifiers: ProductIdentifiers(sku: "B0ACME1234")),
            url: url)

        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(loader.requestedPrimaryURLs, [imageURL])
        for _ in 0..<50 {
            if store.item(forURLString: url.absoluteString)?.priceTracker?.imageFileName != nil {
                break
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let fileName = try XCTUnwrap(
            store.item(forURLString: url.absoluteString)?.priceTracker?.imageFileName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: store.articlesDirectory.appendingPathComponent(fileName).path))
    }

    // MARK: - A match merges instead of duplicating

    func testAShareSheetSaveOfAnAlreadyTrackedGTINMergesRatherThanDuplicating() {
        let existingURL = URL(string: "https://jbhifi.example/p/1")!
        let existingItem = store.add(urlString: existingURL.absoluteString)
        store.savePriceTracker(
            PriceTracker(
                productName: "Hisense HRFD634BW Fridge", firstStoreURL: existingURL.absoluteString,
                price: 1999, currency: "AUD",
                identifiers: ProductIdentifiers(gtin: "9337640009775", brand: "Hisense")),
            for: existingItem.id)

        let newURL = URL(string: "https://binglee.example/p/1")!
        let placeholder = store.add(urlString: newURL.absoluteString)
        let presented = present(
            product: product(name: "Hisense HRFD634BW Fridge", gtin: "9337640009775"), url: newURL)

        XCTAssertTrue(presented.first is PriceTrackingViewController)
        // Exactly one tracker survives, holding both store URLs.
        XCTAssertNil(store.item(withID: placeholder.id), "the placeholder must be removed on merge")
        let merged = store.item(withID: existingItem.id)?.priceTracker
        XCTAssertEqual(
            Set(merged?.stores.map(\.urlString) ?? []),
            [existingURL.absoluteString, newURL.absoluteString])
        XCTAssertEqual(
            store.items().filter { $0.priceTracker != nil }.count, 1,
            "no duplicate tracker must be left behind")
    }

    /// A merge target that has never been compared and still has fewer than
    /// two stores kicks a comparison — exercised end-to-end through the
    /// presenter, not just through `ProductTrackerMerge` directly.
    func testAMergeKicksAComparisonWhenTheTargetHasNeverBeenCompared() {
        let landed = expectation(description: "comparison ran")
        let runner = StubSellerFanOutRunner()
        runner.onRun = { landed.fulfill() }
        SellerComparisonRunner.installed = runner

        let existingURL = URL(string: "https://jbhifi.example/p/1")!
        let existingItem = store.add(urlString: existingURL.absoluteString)
        store.savePriceTracker(
            PriceTracker(
                productName: "Hisense HRFD634BW Fridge", firstStoreURL: existingURL.absoluteString,
                price: 1999, currency: "AUD",
                identifiers: ProductIdentifiers(gtin: "9337640009775", brand: "Hisense")),
            for: existingItem.id)

        let newURL = URL(string: "https://binglee.example/p/1")!
        _ = store.add(urlString: newURL.absoluteString)
        _ = present(product: product(name: "Hisense HRFD634BW Fridge", gtin: "9337640009775"), url: newURL)

        wait(for: [landed], timeout: 5)
    }

    // MARK: - The onboarding rehearsal's product has something to graph

    /// The save lesson's price editor is the production one, graph slot and
    /// all, and a brand-new tracker has no history — so the Price Tracker's
    /// lesson demonstrated price tracking with an empty box captioned "no
    /// price history yet". The rehearsal's product (and ONLY it, matched by
    /// URL) arrives with a fabricated quarter behind it.
    func testTheRehearsalsProductArrivesWithAHistoryToGraph() throws {
        let url = try XCTUnwrap(URL(string: ShareSetupPractice.amayzonURLString))
        _ = store.add(urlString: url.absoluteString)
        _ = present(product: product(name: "eyePhone Air"), url: url)

        let tracker = try XCTUnwrap(store.item(forURLString: url.absoluteString)?.priceTracker)
        let series = PriceHistory.series(for: tracker)
        XCTAssertGreaterThanOrEqual(
            series.count, PriceHistory.minimumDaysForGraph,
            "below this the graph says 'awaiting more data' instead of drawing")
        XCTAssertNotEqual(
            series.map(\.price).min(), series.map(\.price).max(),
            "a flat line demonstrates nothing about tracking a price")
        XCTAssertEqual(
            series.last?.price, tracker.currentBestPrice,
            "the history has to arrive at what the page says the price is today")
    }

    func testAnOrdinaryNewTrackerStillStartsWithNoHistory() throws {
        let url = try XCTUnwrap(URL(string: "https://a.example/p/1"))
        _ = store.add(urlString: url.absoluteString)
        _ = present(product: product(name: "Widget"), url: url)

        let tracker = try XCTUnwrap(store.item(forURLString: url.absoluteString)?.priceTracker)
        XCTAssertTrue(
            PriceHistory.series(for: tracker).isEmpty,
            "a real save's tracker starts watching now and has nothing behind it")
    }
}
