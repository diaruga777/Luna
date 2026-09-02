//
//  PluginModelDrainTests.swift
//  LunaTests
//

@testable import Luna
import LunaHTMLClassification
import LunaIngest
import LunaModels
import LunaPluginKit
import LunaSaves
import LunaStorage
import LunaURLClassification
import XCTest

// MARK: - Fakes

private final class FakeIngestorMediaHandling: IngestorMediaHandling {
    private(set) var calls: [(platform: ContentPlatform, itemID: String?)] = []
    func ingestPlatformItem(
        _ item: SavedItem, platform: ContentPlatform, platformItemID: String?, store: SavesStore
    ) async {
        calls.append((platform, platformItemID))
    }
}

private final class FakeIngestorArticleHandling: IngestorArticleHandling {
    private(set) var persistedContent: ArticleContent?
    private(set) var persistedURL: URL?
    func persistArticle(
        _ content: ArticleContent, html: String, for item: SavedItem, url: URL, store: SavesStore
    ) async {
        persistedContent = content
        persistedURL = url
    }
    func ingestDocument(_ item: SavedItem, store: SavesStore) async {}
    func backfillMissingWebArchives(store: SavesStore) {}
    func backfillMissingThumbnails(store: SavesStore) {}
    func articleBecameReady(_ item: SavedItem) {}
    func preloadPasteboard(content: ArticleContent, sourceURL: URL) {}
    func doubleSaveDestinationIDs() -> [String] { [] }
    func sendToDestination(_ item: SavedItem, destinationID: String) async {}
    func isDestinationConfigured(_ destinationID: String) -> Bool { false }
}

private final class FakeIngestorProductHandling: IngestorProductHandling {
    private(set) var ingestedProduct: ProductInfo?
    func ingestProductTracker(_ item: SavedItem, url: URL, product: ProductInfo, store: SavesStore) async {
        ingestedProduct = product
    }
}

private final class FakeMediaAdopter: MediaModelAdopting {
    var next: PluginAdoptedOutcome = .media(
        assets: [MediaAsset(url: URL(string: "https://cdn.test/v.mp4")!, kind: .video)],
        platform: .instagram, itemID: "abc", title: "A clip", thumbnailURL: nil)
    func adopt(_ model: MediaModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome { next }
}

private final class FakeArticleAdopter: ArticleModelAdopting {
    var next: PluginAdoptedOutcome = .article(
        ArticleContent(title: "A page", blocks: [
            .init(kind: .paragraph, text: String(repeating: "x", count: 20), links: []),
        ]), sourceHTML: "<p>x</p>")
    func adopt(
        _ model: ArticleModel, url: URL, page: CapturedPage, pluginID: String
    ) async -> PluginAdoptedOutcome { next }
}

private final class FakeProductAdopter: ProductModelAdopting {
    var next: PluginAdoptedOutcome?
    func adopt(_ model: ProductModel, url: URL, pluginID: String) async -> PluginAdoptedOutcome {
        next ?? .declined
    }
}

/// The drain's return-to-Safari witness, recording instead of opening.
private final class RecordingReturnOpener: PluginModelReturnOpening {
    private(set) var opened: [URL] = []
    func open(_ url: URL) async { opened.append(url) }
}

/// Swaps the three handler slots for the duration of one test and restores
/// them, the `IngestorKindHandlers` twin of `PluginAdopterScope`.
private struct IngestorHandlerScope {
    private let article: IngestorArticleHandling?
    private let media: IngestorMediaHandling?
    private let product: IngestorProductHandling?

    init() {
        article = IngestorKindHandlers.article
        media = IngestorKindHandlers.media
        product = IngestorKindHandlers.product
    }

    func restore() {
        IngestorKindHandlers.article = article
        IngestorKindHandlers.media = media
        IngestorKindHandlers.product = product
    }
}

/// What `PluginModelDrain` does with a Safari plugin walk's hand-off
/// (`claudedocs/plans/plugin-platform.md` §13.1): adopts the Model, maps the
/// result onto `Outcome`, and reaches the SAME `IngestorKindHandlers`/
/// `SavesIngestor` path a same-process save would.
@MainActor
final class PluginModelDrainTests: XCTestCase {

    private var directory: URL!
    private var store: SavesStore!
    private var ingestor: SavesIngestor!
    private var adopterScope = PluginAdopterScope()
    private var handlerScope = IngestorHandlerScope()

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SavesStore(containerURL: directory)
        ingestor = SavesIngestor(store: store)
        adopterScope = PluginAdopterScope()
        handlerScope = IngestorHandlerScope()
        PluginModelAdopters.media = nil
        PluginModelAdopters.article = nil
        PluginModelAdopters.product = nil
    }

    override func tearDown() {
        adopterScope.restore()
        handlerScope.restore()
        store = nil
        ingestor = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    private func productInfoBuilder(_ model: ProductModel, _ imageURL: URL?) -> ProductInfo {
        ProductInfo(
            name: model.name, priceAmount: model.price.amount,
            priceCurrency: model.price.currency, imageURL: imageURL ?? model.imageURL,
            brand: model.brand, productID: model.productID,
            identifiers: ProductIdentifiers(), sellers: [])
    }

    private func row(kind: String, extra: String, pluginID: String = "app.luna.test") -> PendingPluginModel {
        PendingPluginModel(
            urlString: "https://example.com/p/abc",
            modelJSON: #"{"kind":"\#(kind)",\#(extra)}"#,
            pluginID: pluginID)
    }

    // MARK: - Media

    func testAMediaModelReachesTheMediaHandlerWithThePluginStamped() async {
        let mediaAdopter = FakeMediaAdopter()
        PluginModelAdopters.media = mediaAdopter
        let media = FakeIngestorMediaHandling()
        IngestorKindHandlers.media = media

        let queued = row(kind: "media", extra: #""assets":[{"url":"https://cdn.test/v.mp4","type":"video"}]"#)
        await PluginModelDrain.adopt(
            queued, productInfoBuilder: productInfoBuilder, store: store, ingestor: ingestor)

        XCTAssertEqual(media.calls.count, 1)
        XCTAssertEqual(media.calls.first?.platform, .instagram)
        XCTAssertEqual(media.calls.first?.itemID, "abc")
        let saved = store.itemsByURL(urlString: "https://example.com/p/abc")
        XCTAssertEqual(saved?.pluginID, "app.luna.test")
    }

    func testAnAudiolessMediaOutcomeBecomesASocialOutcomeNotVideo() {
        let outcome = PluginOutcomeMapping.outcome(
            from: .media(
                assets: [MediaAsset(url: URL(string: "https://cdn.test/i.jpg")!, kind: .image)],
                platform: .instagram, itemID: "abc", title: nil, thumbnailURL: nil),
            productInfo: productInfoBuilder)
        guard case let .social(platform, itemID) = outcome else {
            return XCTFail("expected .social for an image-only asset list")
        }
        XCTAssertEqual(platform, .instagram)
        XCTAssertEqual(itemID, "abc")
    }

    // MARK: - Article

    func testAnArticleModelReachesTheArticleHandler() async {
        let articleAdopter = FakeArticleAdopter()
        PluginModelAdopters.article = articleAdopter
        let article = FakeIngestorArticleHandling()
        IngestorKindHandlers.article = article

        let queued = row(kind: "article", extra: #""title":"A page","html":"<p>x</p>""#)
        await PluginModelDrain.adopt(
            queued, productInfoBuilder: productInfoBuilder, store: store, ingestor: ingestor)

        XCTAssertEqual(article.persistedContent?.title, "A page")
        let saved = store.itemsByURL(urlString: "https://example.com/p/abc")
        XCTAssertEqual(saved?.pluginID, "app.luna.test")
    }

    // MARK: - Product

    func testAProductModelUsesTheInjectedProductInfoBuilder() async {
        let productAdopter = FakeProductAdopter()
        let model = ProductModel(name: "A Thing", price: PluginPrice(amount: 12.5, currency: "aud"))
        productAdopter.next = .product(model, imageURL: URL(string: "https://cdn.test/p.jpg"))
        PluginModelAdopters.product = productAdopter
        let product = FakeIngestorProductHandling()
        IngestorKindHandlers.product = product

        let queued = row(
            kind: "product",
            extra: #""name":"A Thing","price":{"amount":"12.5","currency":"aud"}"#)
        await PluginModelDrain.adopt(
            queued, productInfoBuilder: productInfoBuilder, store: store, ingestor: ingestor)

        XCTAssertEqual(product.ingestedProduct?.name, "A Thing")
        XCTAssertEqual(product.ingestedProduct?.imageURL, URL(string: "https://cdn.test/p.jpg"))
    }

    // MARK: - Decline / failure mapping

    func testADeclinedOrFailedAdoptionMapsToNoOutcome() {
        XCTAssertNil(PluginOutcomeMapping.outcome(from: .declined, productInfo: productInfoBuilder))
        XCTAssertNil(PluginOutcomeMapping.outcome(from: .failed(nil), productInfo: productInfoBuilder))
    }

    // MARK: - run() drains the whole queue

    func testRunTakesEveryQueuedRowAndClearsTheStore() async {
        let mediaAdopter = FakeMediaAdopter()
        PluginModelAdopters.media = mediaAdopter
        let media = FakeIngestorMediaHandling()
        IngestorKindHandlers.media = media

        let pending = PendingPluginModelStore(saves: store)
        pending.put(row(kind: "media", extra: #""assets":[{"url":"https://cdn.test/v.mp4","type":"video"}]"#))

        PluginModelDrain.run(
            returningToSource: false, productInfoBuilder: productInfoBuilder,
            pendingStore: pending, store: store, ingestor: ingestor)

        let deadline = Date().addingTimeInterval(5)
        while media.calls.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(media.calls.count, 1)
        XCTAssertTrue(pending.peek().isEmpty, "a drained row must not be handled twice")
    }

    // MARK: - Returning to Safari

    /// The bounce is the hand-off's own marker, not just the deep link's flag:
    /// a row lives an hour, and a manual launch after the marker expired must
    /// stay in the app.
    func testTheDrainReopensTheSourcePageWhileTheReturnMarkerIsFresh() async {
        let opener = RecordingReturnOpener()
        PluginModelDrain.returnOpener = opener
        defer { PluginModelDrain.returnOpener = nil }

        await drainOneRow(returnToSourceUntil: Date().addingTimeInterval(30), opener: opener)
        XCTAssertEqual(opener.opened.map(\.absoluteString), ["https://example.com/p/abc"])
    }

    func testAnExpiredReturnMarkerKeepsTheUserInTheApp() async {
        let opener = RecordingReturnOpener()
        PluginModelDrain.returnOpener = opener
        defer { PluginModelDrain.returnOpener = nil }

        await drainOneRow(returnToSourceUntil: Date().addingTimeInterval(-1), opener: opener)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    func testARowThatNeverCarriedAReturnMarkerDoesNotBounce() async {
        let opener = RecordingReturnOpener()
        PluginModelDrain.returnOpener = opener
        defer { PluginModelDrain.returnOpener = nil }

        await drainOneRow(returnToSourceUntil: nil, opener: opener)
        XCTAssertTrue(opener.opened.isEmpty)
    }

    /// Drains one media row with `ret=safari` set, and waits for the media
    /// handler to have run — the drain's last step is the bounce, so the
    /// opener has been called or skipped by then.
    private func drainOneRow(
        returnToSourceUntil: Date?, opener: RecordingReturnOpener
    ) async {
        PluginModelAdopters.media = FakeMediaAdopter()
        let media = FakeIngestorMediaHandling()
        IngestorKindHandlers.media = media

        let pending = PendingPluginModelStore(saves: store)
        pending.put(PendingPluginModel(
            urlString: "https://example.com/p/abc",
            modelJSON: #"{"kind":"media","assets":[{"url":"https://cdn.test/v.mp4","type":"video"}]}"#,
            pluginID: "app.luna.test", returnToSourceUntil: returnToSourceUntil))

        PluginModelDrain.run(
            returningToSource: true, productInfoBuilder: productInfoBuilder,
            pendingStore: pending, store: store, ingestor: ingestor)

        let deadline = Date().addingTimeInterval(5)
        while media.calls.isEmpty, Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        // The open is one hop past the adoption; give that hop a turn.
        for _ in 0..<10 where opener.opened.isEmpty {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    // MARK: - Deep link

    func testThePluginModelLinkIsRecognizedOnlyByItsOwnHost() {
        let link = URL(string: "luna://pluginmodel")!
        XCTAssertTrue(LunaDeepLink.isPluginModelLink(link))
        XCTAssertFalse(LunaDeepLink.isPluginModelLink(URL(string: "luna://resolvedmedia")!))
        XCTAssertFalse(LunaDeepLink.isResolvedMediaLink(link))
    }

    func testThePluginModelLinkCarriesTheReturnToSourceFlag() {
        XCTAssertTrue(LunaDeepLink.requestsReturnToSource(URL(string: "luna://pluginmodel?ret=safari")!))
        XCTAssertFalse(LunaDeepLink.requestsReturnToSource(URL(string: "luna://pluginmodel")!))
    }
}

private extension SavesStore {
    /// Looks an item up by its exact URL string — the drain reserves under the
    /// row's own `urlString`, so this is the one thing every test here needs.
    func itemsByURL(urlString: String) -> SavedItem? {
        items().first { $0.urlString == urlString }
    }
}
