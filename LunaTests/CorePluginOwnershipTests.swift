import XCTest
import LunaModels
import LunaIngest
import LunaMediaDownload
import LunaPluginIngest
import LunaPluginKit
import LunaPluginRuntime
import LunaPluginUI
import LunaPriceUI
import LunaStorage

final class CorePluginOwnershipTests: XCTestCase {
    private var oldPolicy = false
    private var oldStage: (any PluginIngestStaging)?
    private var adopters = PluginAdopterScope()
    private let urls = [
        "https://amazon.com/dp/B012345678?ref=keep", "https://google.com/search?ibp=oshop&prds=123",
        "https://nytimes.com/2026/story", "https://x.com/a/status/123?s=20",
        "https://youtube.com/watch?v=abc", "https://reddit.com/comments/abc", "https://instagram.com/p/abc",
        "https://facebook.com/watch?v=123", "https://tiktok.com/@a/video/123",
        "https://news.google.com/articles/opaque", "https://cdn.example.test/file.mp4"
    ]
    override func setUp() {
        super.setUp()
        oldPolicy = URLBehaviorPolicy.pluginsOnly
        URLBehaviorPolicy.pluginsOnly = true
        oldStage = IngestPipeline.pluginStage
        adopters = PluginAdopterScope()
        PluginModelAdopters.media = MediaModelAdopter()
    }
    override func tearDown() {
        URLBehaviorPolicy.pluginsOnly = oldPolicy
        IngestPipeline.pluginStage = oldStage
        adopters.restore()
        super.tearDown()
    }
    private var root: URL { URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent() }
    private var pluginSource: String { """
    /* luna-plugin
    {"id":"test.ownership","name":"Ownership","version":"1.0.0","api":1,
     "produces":["media"],"match":{"any":true}}
    */
    luna.register({classify(){return {kind:'media'};},ingest({url}){
        return {kind:'media',assets:[{url:'https://cdn.unknown.test/asset',type:'video'}]};
    }});
    """ }

    func testEmptyDisabledAndRemovedCatalogsAcrossAppShareAndAction() async throws {
        for kind in [PluginProcessKind.app, .share, .action] {
            let runner = PluginJSFixtureRunner(processKind: kind)
            defer { runner.cleanUp() }
            IngestPipeline.pluginStage = PluginIngestStage(invoker: runner.runtime, processKind: kind)
            let fetcher = MockArticleFetcher()
            for raw in urls {
                let url = URL(string: raw)!
                let result = await IngestPipeline.processResolved(IngestInput(url: url, source: .manual), fetcher: fetcher)
                XCTAssertEqual(result.outcome, .link)
                XCTAssertEqual(result.url, url)
            }
            XCTAssertTrue(fetcher.calls.isEmpty)
            XCTAssertTrue(runner.fetcher.requests.isEmpty)
            try runner.load(pluginSource)
            let unknown = URL(string: "https://unfamiliar.test/custom-shape?preserve=1")!
            let enabled = await IngestPipeline.processResolved(IngestInput(url: unknown, source: .manual), fetcher: fetcher)
            XCTAssertEqual(enabled.pluginID, "test.ownership")
            XCTAssertNotEqual(enabled.outcome, .link)
            runner.store.setEnabled(false, pluginID: "test.ownership", isBundled: false)
            runner.runtime.loadAll()
            let disabled = await IngestPipeline.process(IngestInput(url: unknown, source: .manual), fetcher: fetcher)
            XCTAssertEqual(disabled, .link)
            try runner.store.delete(pluginID: "test.ownership")
            runner.runtime.loadAll()
            XCTAssertTrue(runner.runtime.loadedPlugins.isEmpty)
            let removed = await IngestPipeline.process(IngestInput(url: unknown, source: .manual), fetcher: fetcher)
            XCTAssertEqual(removed, .link)
        }
    }

    func testAllShippedPluginsDisabledNeverReappearAsFallbacks() async throws {
        let runner = PluginJSFixtureRunner()
        defer { runner.cleanUp() }
        let catalog = BundledPluginCatalog(source: .directory(root.appendingPathComponent("LunaLibraries/Sources/LunaBundledPlugins/Plugins")), store: runner.store)
        XCTAssertGreaterThan(catalog.plugins().count, 15)
        for plugin in catalog.plugins() { runner.store.setEnabled(false, pluginID: plugin.manifest.id, isBundled: true) }
        let runtime = PluginRuntime(store: runner.store, bundled: catalog,
            processContext: PluginProcessContext(kind: .app), isolated: true)
        runtime.loadAll()
        XCTAssertTrue(runtime.loadedPlugins.isEmpty)
        IngestPipeline.pluginStage = PluginIngestStage(invoker: runtime, processKind: .app)
        let fetcher = MockArticleFetcher()
        for raw in urls {
            let result = await IngestPipeline.process(IngestInput(url: URL(string:raw)!, source:.manual), fetcher:fetcher)
            XCTAssertEqual(result, .link)
        }
        XCTAssertTrue(fetcher.calls.isEmpty)
    }

    func testOwnerPriceRefreshAndComparisonDoNotFallBackWhenRemoved() async throws {
        let runner = PluginJSFixtureRunner()
        defer { runner.cleanUp() }
        try runner.load("""
        /* luna-plugin
        {"id":"test.price","name":"Price","version":"1.0.0","api":1,"produces":["product"],"match":{"any":true}}
        */
        luna.register({classify(){return {kind:'product'};},ingest({reason}){
            return {kind:'product',name:'Widget',price:{amount:'50',currency:'USD'},
            sellers:reason==='compare'?[{url:'https://other.test/widget',price:{amount:'40',currency:'USD'}}]:[]};
        }});
        """)
        let fetcher = PluginPriceFetcher(invoker: runner.runtime, processKind: .app)
        let url = URL(string: "https://shop.test/widget")!
        let price = await fetcher.price(forStoreURL:url, pluginID:"test.price")
        XCTAssertEqual(price?.amount, 50)
        let sellers = await fetcher.sellers(for:url, pluginID:"test.price")
        XCTAssertEqual(sellers.count, 1)
        runner.store.setEnabled(false, pluginID:"test.price", isBundled:false)
        runner.runtime.loadAll()
        let gone = await fetcher.price(forStoreURL:url, pluginID:"test.price")
        XCTAssertNil(gone)
        let missingSellers = await fetcher.sellers(for:url, pluginID:"test.price")
        XCTAssertTrue(missingSellers.isEmpty)
    }

    func testRefreshPreservesLastObservedPriceWithoutOwnerAndNeverUsesNativeFetcher() async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at:dir) }
        let store = SavesStore(containerURL:dir)
        let url = "https://amazon.com/dp/B012345678"
        let item = store.add(urlString:url)
        let tracker = PriceTracker(productName:"Widget",firstStoreURL:url,price:100,currency:"USD")
        _ = store.savePriceTracker(tracker,for:item.id)
        let native = MockPriceFetcher()
        native.priceByURL[url] = .init(amount:1,currency:"USD")
        let result = await PriceRefresher(store:store,priceFetcher:native).refreshTracker(itemID:item.id)
        XCTAssertEqual(result?.newBest,100)
        XCTAssertEqual(result?.unavailableStoreURLs, [url])
        XCTAssertEqual(store.item(withID:item.id)?.priceTracker?.stores.first?.priceHistory, tracker.stores.first?.priceHistory)
        XCTAssertTrue(native.requestedURLs.isEmpty)
    }

    func testDeclinesMalformedErrorsAndTimeoutsKeepTheBaseline() async {
        for answer: FakePluginInvoker.Answer in [.json("null"), .json("{}"), .failure(.timedOut),
                .failure(.exception(message: "fixture", stack: nil))] {
            let invoker = FakePluginInvoker()
            invoker.loadedPlugins = [.fake(id: "p", matchesAnyHost: true)]
            invoker.classifyAnswers["p"] = .json("{\"kind\":\"media\"}")
            invoker.ingestAnswers["p"] = answer
            IngestPipeline.pluginStage = PluginIngestStage(invoker: invoker, processKind: .app)
            let native = MockArticleFetcher()
            let url = URL(string: urls[0])!
            let ordinary = await IngestPipeline.process(IngestInput(url: url, source: .manual), fetcher: native)
            XCTAssertEqual(ordinary, .link)
            let transcript = await IngestPipeline.process(IngestInput(url: url, source: .manual, intent: .transcribe), fetcher: native)
            XCTAssertEqual(transcript, .failed(.noTranscriptSource))
            XCTAssertTrue(native.calls.isEmpty)
        }
    }

    func testForegroundMediaRedispatchIsBoundedAndOwnerCannotChangeOnExpiry() async {
        let invoker = FakePluginInvoker()
        invoker.loadedPlugins = [.fake(id: "wrapper", hosts: ["wrap.test"], produces: [.article]),
                                 .fake(id: "media", hosts: ["new.test"])]
        invoker.classifyAnswers["wrapper"] = .json("{\"kind\":\"article\"}")
        invoker.classifyAnswers["media"] = .json("{\"kind\":\"media\"}")
        invoker.ingestAnswers["wrapper"] = .json("{\"rewriteURL\":\"https://new.test/content\"}")
        invoker.ingestAnswers["media"] = .json("{\"kind\":\"media\",\"assets\":[{\"url\":\"/asset.mp4\",\"type\":\"video\"}]}")
        let resolver = PluginMediaResolver(invoker: invoker, processKind: .app)
        let assets = await resolver.resolveAssets(for: URL(string: "https://wrap.test/x")!)
        XCTAssertEqual(assets.first?.url.absoluteString, "https://new.test/asset.mp4")
        XCTAssertEqual(assets.first?.pluginID, "media")
        let wrongOwner = await resolver.reresolve(sourceURL: URL(string: "https://wrap.test/x")!, pluginID: "wrapper", saveID: nil)
        XCTAssertNil(wrongOwner)
        invoker.ingestAnswers["media"] = .json("{\"rewriteURL\":\"https://wrap.test/x\"}")
        let cycle = await resolver.resolveAssets(for: URL(string: "https://wrap.test/x")!)
        XCTAssertTrue(cycle.isEmpty)
    }

    func testBrowserInstructionsRoundTripAndRejectOversizedPayloads() throws {
        let request = try XCTUnwrap(PluginBrowserRequest(jsObject:["url":"https://example.test/p", "detect":"'done'", "scripts":["document.body.dataset.test='yes'"], "blockURLs":[".*meter[.]js"]]))
        XCTAssertEqual(PluginBrowserRequest(json: try XCTUnwrap(request.jsonText)), request)
        XCTAssertNil(PluginBrowserRequest(jsObject:["url":"https://example.test/p","detect":"'done'","blockURLs":Array(repeating:"x",count:101)]))
        let legacy = try XCTUnwrap(PluginBrowserRequest(url:URL(string:"https://example.test/p")!,detect:"'done'").jsonText)
        XCTAssertNil(PluginBrowserRequest(json:legacy)?.scripts)
        XCTAssertNil(PluginBrowserRequest(json: #"{"url":"httpx://example.test","detect":"done"}"#))
    }
}
