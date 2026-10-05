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
}
