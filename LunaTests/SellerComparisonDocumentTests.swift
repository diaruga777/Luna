//
//  SellerComparisonDocumentTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import LunaPriceUI

/// The comparison summary the Action Button intents return
/// (`claudedocs/price-comparison.md`). Structure, not pixels: what the file must
/// contain to still work after it has been AirDropped somewhere with no network.
final class SellerComparisonDocumentTests: XCTestCase {

    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func row(
        _ name: String, price: String?, currency: String = "USD",
        favicon: String? = nil
    ) -> SellerComparisonDocument.SellerRow {
        SellerComparisonDocument.SellerRow(
            name: name, urlString: "https://\(name.lowercased()).example/p/1",
            price: price.map { Decimal(string: $0)! }, currency: currency,
            faviconDataURI: favicon)
    }

    private func content(
        rows: [SellerComparisonDocument.SellerRow],
        series: [PriceGraphPoint] = [],
        image: String? = nil,
        productName: String = "Acme Widget"
    ) -> SellerComparisonDocument.Content {
        SellerComparisonDocument.Content(
            productName: productName, productImageDataURI: image, sellers: rows,
            series: series, displayCurrency: "USD", generatedAt: stamp)
    }

    private func points(_ prices: [String]) -> [PriceGraphPoint] {
        prices.enumerated().map { index, price in
            PriceGraphPoint(
                date: stamp.addingTimeInterval(Double(index) * 86_400),
                price: Decimal(string: price)!, currency: "USD",
                storeURLString: "https://a.example/p/1")
        }
    }

    // MARK: - Self-containment

    /// The one property the whole design exists for: a Quick Look, a Files
    /// preview and a mail attachment all render this with no network and no base
    /// URL, so any reference out of the file is a hole in it.
    func testTheDocumentReferencesNothingOutsideItself() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80", favicon: "data:image/png;base64,AAAA")],
            series: points(["100", "90", "80"]),
            image: "data:image/jpeg;base64,BBBB"))
        for attribute in ["src=\"http", "href=\"http://cdn", "@import", "<script"] {
            XCTAssertFalse(html.contains(attribute), "found \(attribute)")
        }
        XCTAssertFalse(
            html.contains("<link"), "an external stylesheet would render as unstyled text")
        XCTAssertTrue(html.contains("<style>"))
    }

    func testItCarriesBothAppearancesRatherThanForcingLunasOwn() {
        let html = SellerComparisonDocument.html(content(rows: [row("Amazon", price: "80")]))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("color-scheme: light dark"))
    }

    func testTheProductImageIsEmbeddedAtTheTop() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], image: "data:image/jpeg;base64,BBBB"))
        let hero = try? XCTUnwrap(html.range(of: "class=\"hero\""))
        let heading = try? XCTUnwrap(html.range(of: "<h1>"))
        XCTAssertNotNil(hero)
        XCTAssertNotNil(heading)
        if let hero = hero as? Range<String.Index>, let heading = heading as? Range<String.Index> {
            XCTAssertLessThan(hero.lowerBound, heading.lowerBound)
        }
        XCTAssertTrue(html.contains("src=\"data:image/jpeg;base64,BBBB\""))
    }

    // MARK: - Sellers

    func testEverySellerIsAListedLinkWithItsPrice() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80"), row("Target", price: "120")]))
        XCTAssertTrue(html.contains("href=\"https://amazon.example/p/1\""))
        XCTAssertTrue(html.contains("href=\"https://target.example/p/1\""))
        XCTAssertTrue(html.contains("$80.00"))
        XCTAssertTrue(html.contains("$120.00"))
    }

    /// Exactly one row is badged, and it is the cheapest — the whole question
    /// the file answers.
    func testOnlyTheLowestPricedSellerIsHighlighted() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80"), row("Target", price: "120")]))
        XCTAssertEqual(
            html.components(separatedBy: "class=\"seller lowest\"").count - 1, 1)
        let lowest = html.range(of: "class=\"seller lowest\"")!
        let amazon = html.range(of: "amazon.example")!
        let target = html.range(of: "target.example")!
        XCTAssertLessThan(lowest.lowerBound, amazon.lowerBound)
        XCTAssertLessThan(amazon.lowerBound, target.lowerBound)
    }

    func testASellerWithNoFaviconGetsAPlaceholderRatherThanABrokenImage() {
        let html = SellerComparisonDocument.html(content(rows: [row("Amazon", price: "80")]))
        XCTAssertTrue(html.contains("class=\"icon placeholder\""))
        XCTAssertFalse(html.contains("<img class=\"icon\""))
    }

    func testAnUnpricedSellerIsShownRatherThanDropped() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80"), row("Target", price: nil)]))
        XCTAssertTrue(html.contains("class=\"price none\""))
        XCTAssertTrue(html.contains("target.example"))
    }

    // MARK: - The graph

    func testTheGraphIsInlineSVGWithLabelledPriceAndDateAxes() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], series: points(["100", "90", "80"])))
        XCTAssertTrue(html.contains("<svg class=\"graph\""))
        XCTAssertTrue(html.contains("class=\"axis price\""))
        XCTAssertTrue(html.contains("class=\"axis date start\""))
        XCTAssertTrue(html.contains("class=\"axis date end\""))
        XCTAssertTrue(html.contains("$100.00"), "the high end of the price axis")
    }

    func testASingleDataPointDrawsNoGraphAtAll() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], series: points(["100"])))
        XCTAssertFalse(html.contains("<svg"))
        XCTAssertTrue(html.contains("class=\"empty\""))
    }

    /// A price that never moved is a real series, and dividing by its zero span
    /// would produce `NaN` coordinates and an empty plot.
    func testAFlatSeriesStillDrawsALine() {
        let svg = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["50", "50", "50"])))
        XCTAssertFalse(svg.contains("nan"))
        XCTAssertFalse(svg.lowercased().contains("inf"))
        XCTAssertTrue(svg.contains("class=\"line\""))
    }

    // MARK: - Escaping and naming

    func testAProductNameCannotBreakOutOfTheMarkup() {
        let html = SellerComparisonDocument.html(content(
            rows: [], productName: "<script>alert('x')</script> & \"quoted\""))
        XCTAssertFalse(html.contains("<script>alert"))
        XCTAssertTrue(html.contains("&lt;script&gt;"))
        XCTAssertTrue(html.contains("&amp;"))
    }

    func testTheFileNameIsSafeAndKeepsTheProductRecognisable() {
        XCTAssertEqual(
            SellerComparisonDocument.fileName(for: "Acme / Widget"), "Acme - Widget.html")
        XCTAssertEqual(SellerComparisonDocument.fileName(for: "  "), "Price comparison.html")
    }

    /// A favicon's declared `data:` type has to come from the BYTES: favicons
    /// are served with every wrong `Content-Type` there is, and a wrong type in
    /// a data URI simply does not render.
    func testTheImageTypeIsReadFromTheBytes() {
        XCTAssertEqual(
            SellerComparisonDocument.mimeType(
                forImageData: Data([0x89, 0x50, 0x4E, 0x47, 0, 0, 0, 0])), "image/png")
        XCTAssertEqual(
            SellerComparisonDocument.mimeType(
                forImageData: Data([0xFF, 0xD8, 0xFF, 0xE0])), "image/jpeg")
        XCTAssertEqual(
            SellerComparisonDocument.mimeType(
                forImageData: Data([0x00, 0x00, 0x01, 0x00, 1, 0])), "image/x-icon")
    }

    // MARK: - Assembly from a tracker

    func testRowsComeOutCheapestFirstWithUnpricedStoresLast() async {
        var tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://source.example/p/1",
            price: 100, currency: "USD")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://cheap.example/p/1", lastPrice: 55, currency: "USD"))
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://unknown.example/p/1", lastPrice: nil, currency: "USD"))
        let content = await SellerComparisonDocument.content(
            for: tracker, articlesDirectory: FileManager.default.temporaryDirectory,
            now: stamp, faviconLoader: { _ in nil })
        XCTAssertEqual(content.sellers.map(\.name), ["Cheap", "Source", "Unknown"])
        XCTAssertNil(content.sellers.last?.price)
    }

    func testASingleStoreTrackerProducesNoDocument() async {
        let tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://source.example/p/1",
            price: 100, currency: "USD")
        let url = await SellerComparisonDocument.write(
            for: tracker, articlesDirectory: FileManager.default.temporaryDirectory)
        XCTAssertNil(url, "one price is not a comparison")
    }

    func testSellerNamesComeFromTheRegistrableDomain() {
        XCTAssertEqual(
            SellerComparisonDocument.sellerName(
                forURLString: "https://www.amazon.co.uk/dp/B01"), "Amazon")
        XCTAssertEqual(
            SellerComparisonDocument.sellerName(
                forURLString: "https://shop.example.com/p/1"), "Example")
    }
}
