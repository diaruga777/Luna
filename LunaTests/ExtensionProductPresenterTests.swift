//
//  ExtensionProductPresenterTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaStorage
@testable import LunaPriceUI
import UIKit
import XCTest

/// The extension's immediate-editor path: before it asked `ProductTrackerMerge`,
/// a share-sheet save of an already-tracked product created a SECOND tracker
/// instead of merging into the first — even when both pages declared the same
/// GTIN. These pin the merge outcome at the presenter's own level: the
/// placeholder item is removed, the existing tracker gains the store, and no
/// duplicate tracker is left behind.
@MainActor
final class ExtensionProductPresenterTests: XCTestCase {

    private var tempDirectory: URL!
    private var store: ReadingListStore!
    private var presenter: ExtensionProductPresenter!

    override func setUp() {
        super.setUp()
        SellerComparisonRunner.installed = nil
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionProductPresenterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        store = ReadingListStore(containerURL: tempDirectory)
        presenter = ExtensionProductPresenter()
        presenter.snapshotProvider = { [] }
        presenter.artworkLoader = { _, _ in nil }
    }

    override func tearDown() {
        SellerComparisonRunner.installed = nil
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }

    private func product(name: String, gtin: String? = nil, brand: String? = "Hisense") -> ProductInfo {
        ProductInfo(
            name: name, priceAmount: 1999, priceCurrency: "AUD", imageURL: nil, brand: brand,
            productID: gtin, identifiers: ProductIdentifiers(gtin: gtin, brand: brand))
    }

    /// `presentModally` is called SYNCHRONOUSLY on both outcomes
    /// (`presentPriceEditor` never awaits anything itself); `complete` is the
    /// EDITOR's own Done callback (`editor.onDone = complete`), fired only
    /// when the user finishes with it — never during this call — except on
    /// the early failure path (no placeholder item), which calls it directly.
    private func present(product: ProductInfo, url: URL) -> [UIViewController] {
        var presented: [UIViewController] = []
        presenter.presentPriceEditor(
            product: product, url: url, store: store,
            presentModally: { presented.append($0) },
            complete: {})
        return presented
    }

    // MARK: - No match: creates a new tracker, as before

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
        presenter.artworkLoader = { primaryURL, _ in
            XCTAssertEqual(primaryURL, imageURL)
            loaded.fulfill()
            return Data("amazon-artwork".utf8)
        }
        _ = store.add(urlString: url.absoluteString)
        _ = present(
            product: ProductInfo(
                name: "Acme", priceAmount: 42, priceCurrency: "AUD",
                imageURL: imageURL, brand: nil, productID: "B0ACME1234",
                identifiers: ProductIdentifiers(sku: "B0ACME1234")),
            url: url)

        await fulfillment(of: [loaded], timeout: 2)
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
        SellerComparisonRunner.installed = { _, _ in
            landed.fulfill()
            return SellerFanOutOutcome(results: [], attemptedSellerIDs: [], stopReason: .exhausted)
        }

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
