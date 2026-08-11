//
//  ProductIngestProcessorTests.swift
//  LunaTests
//

import LunaHTMLClassification
import LunaModels
import LunaPriceCompare
import LunaPriceIngest
import XCTest

/// The APP-side capture site: every page the shared ingest pipeline classifies
/// as a product is recorded as an observation, in whichever process did the
/// classifying — the app, the share extension, the action extension.
///
/// This is the half that did not exist. The Safari extension has always
/// recorded what it saw; nothing else did, so a user who saves through the app,
/// the share sheet or the Action Button accumulated an empty store and every
/// tracker was born with a single point.
final class ProductIngestProcessorTests: XCTestCase {

    private var directory: URL?
    private var snapshots: ProductSnapshotStore!

    override func setUp() {
        super.setUp()
        snapshots = .temporary(directory: &directory)
    }

    override func tearDown() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        super.tearDown()
    }

    private static let productHTML = """
    <html><head><title>Acme Widget</title>
    <script type="application/ld+json">
    {"@context":"https://schema.org","@type":"Product","name":"Acme Widget",
     "brand":{"@type":"Brand","name":"Acme"},"gtin13":"0012345678905",
     "mpn":"AW-9","sku":"SKU-42",
     "offers":{"@type":"Offer","price":"49.99","priceCurrency":"USD"}}
    </script></head><body></body></html>
    """

    private let pageURL = URL(string: "https://shop.example/p/widget")!

    func testAClassifiedProductPageIsRecordedAsAnObservation() async throws {
        let processor = ProductIngestProcessor(snapshotStore: snapshots)
        let product = try XCTUnwrap(
            await processor.extract(url: pageURL, html: Self.productHTML))
        XCTAssertEqual(product.name, "Acme Widget")

        let observed = snapshots.snapshots(forKeys: ProductSnapshotKeys.gtinKeys("0012345678905"))
        XCTAssertEqual(observed.count, 1, "the visit must be findable by the page's GTIN")
        XCTAssertEqual(observed.first?.price, "49.99")
        XCTAssertEqual(observed.first?.host, "shop.example")
        XCTAssertEqual(observed.first?.url, pageURL.absoluteString)
    }

    /// Every identifier the page declared becomes a way back to the
    /// observation, because the identifier a LATER save happens to carry is not
    /// knowable now.
    func testTheObservationIsFiledUnderEveryIdentifierThePageDeclared() async {
        let processor = ProductIngestProcessor(snapshotStore: snapshots)
        _ = await processor.extract(url: pageURL, html: Self.productHTML)

        for keys in [ProductSnapshotKeys.gtinKeys("0012345678905"),
                     ProductSnapshotKeys.mpnKeys("AW-9"),
                     ProductSnapshotKeys.skuKeys("SKU-42", host: "shop.example"),
                     [ProductSnapshotKeys.urlKey(pageURL.absoluteString)]] {
            XCTAssertEqual(
                snapshots.snapshots(forKeys: keys).count, 1,
                "no observation reachable through \(keys)")
        }
    }

    /// A page that is not a priced product yields nothing to observe, and must
    /// not leave a record behind.
    func testAPageWithNoProductRecordsNothing() async {
        let processor = ProductIngestProcessor(snapshotStore: snapshots)
        let product = await processor.extract(
            url: URL(string: "https://blog.example/post")!,
            html: "<html><body><p>Just an article.</p></body></html>")
        XCTAssertNil(product)
        XCTAssertEqual(snapshots.count(), 0)
    }
}
