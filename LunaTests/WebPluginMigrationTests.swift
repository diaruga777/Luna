import XCTest
import LunaModels
import LunaPluginKit
import LunaPluginIngest

final class WebPluginMigrationTests: XCTestCase {
    private var runner: PluginJSFixtureRunner!
    private var root: URL { URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent() }
    override func setUp() { super.setUp(); runner=PluginJSFixtureRunner() }
    override func tearDown() { runner.cleanUp(); runner=nil; super.tearDown() }
    private func load(_ name:String) throws {
        try runner.load(String(contentsOf:root.appendingPathComponent("LunaLibraries/Sources/LunaBundledPlugins/Plugins/\(name).js"),encoding:.utf8))
    }
    func testRetailAndShoppingFixturesUseTheShippingPluginInJSC() async throws {
        try load("web")
        for (fixture,url,expected,currency) in [
            ("amazon-dp","https://amazon.com.au/dp/X","39.99","AUD"),
            ("amazon-listprice","https://amazon.com/dp/X","42.50","USD"),
            ("target-nextdata","https://target.com/p/test/-/A-123","24.99","USD"),
            ("walmart-nextdata","https://walmart.com/ip/123","17.88","USD"),
            ("google-shopping-mova","https://google.com/search?tbm=shop","1098","AUD"),
            ("google-shopping-ibp-oshop","https://google.com/search?ibp=oshop&prds=123","459","AUD")
        ] {
            let html=try String(contentsOf:root.appendingPathComponent("LunaTests/Fixtures/Products/\(fixture).html"),encoding:.utf8)
            runner.fetcher.respond(to:url,body:html)
            let answer: PluginIngestAnswer? = await runner.invoke(.ingest,pluginID:"app.luna.web",
                argument:PluginIngestHookInput(url:url,claim:.init(kind:.product,itemID:nil),page:nil,reason:.save,context:.app),as:PluginIngestAnswer.self)
            guard case let .model(.product(product)) = answer else { XCTFail("No product for \(fixture)"); continue }
            XCTAssertEqual(product.price.amount,Decimal(string:expected),fixture)
            XCTAssertEqual(product.price.currency,currency,fixture)
            if fixture.hasPrefix("google") { XCTAssertFalse(product.sellers.isEmpty) }
        }
    }
    func testPublisherAMPStrategySelectsAndConvertsArticleInJSC() async throws {
        try load("publisher-access")
        let url="https://theaustralian.com.au/news/story"
        runner.fetcher.respond(to:url,body:"<article><p>Subscribe to read</p></article>")
        runner.fetcher.respond(to:url+"?amp",body:"<article><p>"+String(repeating:"The complete recovered article text. ",count:100)+"</p></article>")
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest,pluginID:"app.luna.publisher-access",
            argument:PluginIngestHookInput(url:url,claim:.init(kind:.article,itemID:nil),page:nil,reason:.save,context:.app),timeout:10,as:PluginIngestAnswer.self)
        guard case let .model(.article(article)) = answer else { return XCTFail("No article") }
        XCTAssertTrue(article.html.contains("complete recovered"))
        XCTAssertTrue(runner.fetcher.requests.contains { $0.url.absoluteString == url+"?amp" })
    }

    func testReadableDailyBeastArchiveDoesNotWaitForStalledOldestLookupInJSC() async throws {
        try load("publisher-access")
        let url = "https://www.thedailybeast.com/animated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing"
        let encoded = "https%3A%2F%2Fwww.thedailybeast.com%2Fanimated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing"
        let query = "https://web.archive.org/cdx/search/cdx?url=\(encoded)&output=json&filter=statuscode:200&filter=mimetype:text/html&collapse=timestamp:6&limit=1"
        let gated = "<article><p>Subscribe to read</p></article>"
        // Synthetic prose in the archive's article shape; large script payloads
        // and a metered declaration must not prevent an available full body.
        let html = """
        <html><head><title>Recovered article</title>
        <script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script>
        </head><body><article id="main-article">
        <p class="c-paragraph">\(String(repeating: "Complete archived reporting. ", count: 150))</p>
        </article><script>\(String(repeating: " ", count: 600_000))</script></body></html>
        """
        runner.fetcher.respond(to: url, body: gated)
        runner.fetcher.respond(to: query+"&sort=reverse", body: #"[["timestamp"],["20260307154638"]]"#)
        runner.fetcher.respond(to: query, body: "[]")
        runner.fetcher.delays[query] = 5
        runner.fetcher.respond(to: "https://web.archive.org/web/20260307154638id_/"+url, body: html)
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
            argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                page: .init(url: url, html: gated, source: "fetch"), reason: .save, context: .app), timeout: 2, as: PluginIngestAnswer.self)
        guard case let .model(.article(article)) = answer else { return XCTFail("No article") }
        XCTAssertTrue(article.html.contains("Complete archived reporting"))
        XCTAssertTrue(runner.fetcher.requests.contains { $0.url.absoluteString == query })
    }

    struct ArticleParityCase: Decodable {
        let name: String
        let url: String
        let html: String
        let contains: [String]
        let excludes: [String]
        let isNull: Bool
    }
    func testLegacyArticleFixturesThroughShippingJavaScriptCorePlugin() async throws {
        try load("web")
        let data = try Data(contentsOf: root.appendingPathComponent("LunaTests/Fixtures/Plugins/web-parity.json"))
        for fixture in try JSONDecoder().decode([ArticleParityCase].self, from: data) {
            let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.web",
                argument: PluginIngestHookInput(url: fixture.url, claim: .init(kind: .article, itemID: nil),
                    page: .init(url: fixture.url, html: fixture.html, source: "fetch"), reason: .save, context: .app), as: PluginIngestAnswer.self)
            if fixture.isNull {
                guard case .declined = answer else { XCTFail("Expected decline: \(fixture.name)"); continue }
            } else {
                guard case let .model(.article(article)) = answer else { XCTFail("No article: \(fixture.name)"); continue }
                // DOM serializers differ in whitespace; compare normalized markup.
                func normalize(_ text: String) -> String { text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression) }
                for value in fixture.contains { XCTAssertTrue(normalize(article.html).contains(normalize(value)), fixture.name) }
                for value in fixture.excludes { XCTAssertFalse(article.html.contains(value), fixture.name) }
            }
        }
    }
    func testGenericEmbeddedRetailFixtures() async throws {
        try load("web")
        for (fixture, expected) in [("bunnings-nextdata", "99"), ("nested-currency-state", "49.9")] {
            let url = "https://shop.example/products/thing"
            let html = try String(contentsOf: root.appendingPathComponent("LunaTests/Fixtures/Products/\(fixture).html"), encoding: .utf8)
            runner.fetcher.respond(to: url, body: html)
            let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.web",
                argument: PluginIngestHookInput(url: url, claim: .init(kind: .product, itemID: nil), page: nil, reason: .refresh, context: .app), as: PluginIngestAnswer.self)
            guard case let .model(.product(product)) = answer else { XCTFail("No product: \(fixture)"); continue }
            XCTAssertEqual(product.price.amount, Decimal(string: expected))
            XCTAssertEqual(product.price.currency, "AUD")
        }
    }
}
