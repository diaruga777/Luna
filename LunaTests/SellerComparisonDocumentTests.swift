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
        current: String? = nil,
        image: String? = nil,
        productName: String = "Acme Widget"
    ) -> SellerComparisonDocument.Content {
        SellerComparisonDocument.Content(
            productName: productName, productImageDataURI: image, sellers: rows,
            series: series, currentPrice: current.map { Decimal(string: $0)! },
            displayCurrency: "USD", generatedAt: stamp)
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
        XCTAssertTrue(html.contains(">100.00</text>"), "the high end of the price axis")
        XCTAssertEqual(
            html.components(separatedBy: "class=\"axis currency\"").count - 1, 1,
            "the currency belongs once at the top of the y axis")
    }

    func testASingleDataPointStillDrawsTheStaticIntentGraph() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], series: points(["100"])))
        XCTAssertTrue(html.contains("<svg class=\"graph\""))
        XCTAssertTrue(html.contains("class=\"dot\""))
    }

    func testEmptyHistoryStillDrawsTheStaticIntentGraph() {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], series: []))
        XCTAssertTrue(html.contains("<svg class=\"graph\""))
        XCTAssertTrue(html.contains("class=\"axis empty-history\""))
        XCTAssertFalse(html.contains("<path class=\"line\" d=\"\""))
    }

    func testStaticIntentOrderIsProductThenSellersThenGraphAndNeverAlertConfiguration() throws {
        let html = SellerComparisonDocument.html(content(
            rows: [row("Amazon", price: "80")], series: points(["100", "80"]),
            image: "data:image/png;base64,AAAA"))
        let title = try XCTUnwrap(html.range(of: "<h1>"))
        let sellers = try XCTUnwrap(html.range(of: "<ul class=\"sellers\""))
        let graph = try XCTUnwrap(html.range(of: "<svg class=\"graph\""))
        XCTAssertLessThan(title.lowerBound, sellers.lowerBound)
        XCTAssertLessThan(sellers.lowerBound, graph.lowerBound)
        XCTAssertFalse(html.lowercased().contains("alert at"))
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

    // MARK: - The graph spans the whole record

    /// The document's SVG is 640 points wide and read at any size, so it takes
    /// the FULL day-resolution history rather than the on-screen graph's
    /// span-coarsened view. A year of pruned history is at most 365 points.
    func testTheGraphTakesEveryDayOfHistoryRatherThanACoarsenedView() async {
        var store = PriceTrackerStore(
            urlString: "https://source.example/p/1", lastPrice: 100, currency: "USD")
        let day = 86_400.0
        for index in 0..<200 {
            store.recordSample(
                price: Decimal(100 + index % 7), currency: "USD",
                at: stamp.addingTimeInterval(-Double(index) * day))
        }
        var tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://a.example/p/1",
            price: 100, currency: "USD")
        tracker.upsertStore(store)
        // The on-screen series re-buckets a 200-day span down to weeks…
        XCTAssertLessThan(PriceHistory.series(for: tracker).count, 60)
        // …the document keeps every day of it.
        let content = await SellerComparisonDocument.content(
            for: tracker, articlesDirectory: FileManager.default.temporaryDirectory,
            now: stamp, faviconLoader: { _ in nil })
        XCTAssertEqual(content.series.count, 200)
    }

    /// Past a couple of months a dot per day is a solid bar, so the markers
    /// retire and the line carries the shape — the POINTS are all still plotted.
    func testALongSeriesKeepsEveryPointOnTheLineWithoutDrawingEveryDot() {
        let long = points((0..<120).map { String(100 + $0 % 5) })
        let svg = SellerComparisonDocument.graphSVG(content(rows: [], series: long))
        XCTAssertEqual(svg.components(separatedBy: "<circle").count - 1, 0)
        XCTAssertEqual(Self.pathYValues(in: svg).count, 120)
    }

    // MARK: - The price axis

    /// The lowest point must sit slightly ABOVE the floor of the plot: a line
    /// touching the frame reads as clipped rather than as a low.
    func testTheLowestPointSitsAboveTheBottomEdge() {
        let svg = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["100", "90", "80"]), current: "80"))
        let plotFloor = SellerComparisonDocument.graphHeight - 34  // inset.bottom
        let ys = Self.pathYValues(in: svg)
        let lowestDrawn = try? XCTUnwrap(ys.max())
        XCTAssertNotNil(lowestDrawn)
        if let lowestDrawn = lowestDrawn as? Double {
            XCTAssertLessThan(lowestDrawn, plotFloor, "the minimum must not touch the floor")
            XCTAssertGreaterThan(lowestDrawn, plotFloor - 40, "…but it is still near it")
        }
    }

    /// Three numbers make a history mean something: the high, the low and today.
    func testThePriceAxisAlwaysLabelsTheHighTheLowAndToday() {
        let svg = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["100", "120", "90"]), current: "95"))
        for label in ["120.00", "90.00", "95.00"] {
            XCTAssertTrue(svg.contains(label), "missing \(label)")
        }
        XCTAssertEqual(svg.components(separatedBy: "class=\"axis price\"").count - 1, 3)
    }

    func testCoincidingAxisValuesCollapseIntoOneLabel() {
        // Today IS the low: two of the three values are the same number.
        let two = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["100", "120", "90"]), current: "90"))
        XCTAssertEqual(two.components(separatedBy: "class=\"axis price\"").count - 1, 2)
        // A flat series at today's price: all three coincide.
        let one = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["50", "50", "50"]), current: "50"))
        XCTAssertEqual(one.components(separatedBy: "class=\"axis price\"").count - 1, 1)
        XCTAssertFalse(one.contains("nan"))
    }

    /// A current price outside the history's own range (a drop since the last
    /// recorded day) still has to be inside the plot, or its label floats off it.
    func testACurrentPriceBelowTheRecordStillLandsInsideThePlot() {
        let svg = SellerComparisonDocument.graphSVG(content(
            rows: [], series: points(["100", "110"]), current: "40"))
        XCTAssertTrue(svg.contains(">40.00</text>"))
        for y in Self.axisYValues(in: svg) {
            XCTAssertGreaterThanOrEqual(y, 0)
            XCTAssertLessThanOrEqual(y, SellerComparisonDocument.graphHeight)
        }
    }

    /// When no current price is given the cheapest listed seller IS today's
    /// price — the document's whole subject.
    func testTheCurrentPriceDefaultsToTheCheapestSeller() {
        let value = content(rows: [row("Amazon", price: "80"), row("Target", price: "120")])
        XCTAssertEqual(value.currentPrice, Decimal(80))
    }

    // MARK: - Favicons

    func testAFetchedFaviconIsEmbeddedAsADataURIWithItsRealType() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0), count: 16))
        var tracker = PriceTracker(
            productName: "Acme Widget", firstStoreURL: "https://amazon.example/p/1",
            price: 100, currency: "USD")
        tracker.upsertStore(PriceTrackerStore(
            urlString: "https://target.example/p/1", lastPrice: 90, currency: "USD"))
        let content = await SellerComparisonDocument.content(
            for: tracker, articlesDirectory: FileManager.default.temporaryDirectory,
            now: stamp,
            faviconLoader: { url in url.host == "amazon.example" ? png : nil })
        let html = SellerComparisonDocument.html(content)
        XCTAssertTrue(html.contains("<img class=\"icon\" src=\"data:image/png;base64,"))
        // The other seller is not a gap: it gets an initial badge.
        XCTAssertTrue(html.contains(">T</span>"))
        XCTAssertEqual(html.components(separatedBy: "class=\"icon placeholder\"").count - 1, 1)
    }

    /// One host that never answers must not cost every OTHER row its icon —
    /// which is what a sequential, unbounded fetch does inside an intent that
    /// gives up first.
    func testAHangingFaviconHostOnlyCostsItsOwnRow() async {
        let png = Data([0x89, 0x50, 0x4E, 0x47] + Array(repeating: UInt8(0), count: 16))
        let icons = await SellerComparisonDocument.favicons(
            forStoreURLStrings: ["https://slow.example/p/1", "https://fast.example/p/1"],
            loader: { url in
                if url.host == "slow.example" {
                    try? await Task.sleep(nanoseconds: 30_000_000_000)
                    return nil
                }
                return png
            })
        XCTAssertNil(icons["https://slow.example/p/1"])
        XCTAssertNotNil(icons["https://fast.example/p/1"])
    }

    func testAPlaceholderBadgeCarriesTheSellersInitial() {
        XCTAssertEqual(SellerComparisonDocument.initial(forSellerName: "amazon"), "A")
        XCTAssertEqual(SellerComparisonDocument.initial(forSellerName: "7-Eleven"), "7")
        XCTAssertEqual(SellerComparisonDocument.initial(forSellerName: "…"), "•")
    }

    // MARK: - SVG parsing helpers

    private static func numbers(in svg: String, pattern: String, group: Int) -> [Double] {
        let regex = try! NSRegularExpression(pattern: pattern)
        let range = NSRange(svg.startIndex..., in: svg)
        return regex.matches(in: svg, range: range).compactMap { match in
            guard let r = Range(match.range(at: group), in: svg) else { return nil }
            return Double(svg[r])
        }
    }

    /// Every y coordinate on the plotted LINE (not the filled area beneath it,
    /// whose closing segments sit on the floor by construction).
    private static func pathYValues(in svg: String) -> [Double] {
        let line = try! NSRegularExpression(pattern: "class=\"line\" d=\"([^\"]*)\"")
        let range = NSRange(svg.startIndex..., in: svg)
        guard let match = line.firstMatch(in: svg, range: range),
              let r = Range(match.range(at: 1), in: svg) else { return [] }
        return numbers(in: String(svg[r]), pattern: "[ML][0-9.]+ ([0-9.]+)", group: 1)
    }

    /// Every y coordinate of a price-axis label.
    private static func axisYValues(in svg: String) -> [Double] {
        numbers(in: svg, pattern: "class=\"axis price\" x=\"[0-9.-]+\" y=\"([0-9.-]+)\"", group: 1)
    }

    /// The bundled directory names a retailer it knows ("Amazon UK"); a host it
    /// has never heard of falls back to its registrable domain, capitalised.
    /// Same answer as the seller rows on the card — one `SellerNaming`.
    func testSellerNamesComeFromTheDirectoryThenTheRegistrableDomain() {
        XCTAssertEqual(
            SellerComparisonDocument.sellerName(
                forURLString: "https://www.amazon.co.uk/dp/B01"), "Amazon UK")
        XCTAssertEqual(
            SellerComparisonDocument.sellerName(
                forURLString: "https://shop.example.com/p/1"), "Example")
        XCTAssertEqual(
            SellerNaming.displayName(forURLString: "https://www.jbhifi.com.au/p/1"), "JB Hi-Fi")
    }
}
