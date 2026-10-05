import XCTest

@MainActor
final class CoreSafariOwnershipTests: XCTestCase {
    private lazy var js = SafariJSTestHarness(self)

    func testEmptyEffectiveCatalogIgnoresNativeRulesAndStaleCachedPlugins() {
        for url in ["https://amazon.com/dp/X", "https://google.com/search?tbm=shop",
                    "https://nytimes.com/2026/story", "https://x.com/a/status/123",
                    "https://youtube.com/watch?v=abc", "https://reddit.com/comments/abc",
                    "https://instagram.com/p/abc", "https://facebook.com/watch?v=123",
                    "https://tiktok.com/@a/video/123", "https://news.google.com/articles/opaque",
                    "https://cdn.example.test/video.mp4"] {
            js.load(html: "<article><h1>Story</h1><p>" + String(repeating: "Article prose. ", count: 200)
                    + "</p><video></video></article><script type='application/ld+json'>"
                    + "{\"@type\":\"Product\",\"name\":\"Widget\",\"offers\":{\"price\":50,\"priceCurrency\":\"USD\"}}</script>",
                    urlString: url, scripts: [SafariJSSource.platformHosts, SafariJSSource.newsHosts,
                                               SafariJSSource.productRules, SafariJSSource.content])
            js.evaluate("""
                window.calls=[];
                window.browser={runtime:{sendMessage:function(message){
                    calls.push(message.type);
                    return Promise.resolve({stamp:'disabled',plugins:[]});
                }},storage:{local:{get:function(key){
                    var value={}; value[key]={stamp:'old',plugins:[{id:'stale',any:true,produces:['media']}]};
                    return Promise.resolve(value);
                },set:function(){return Promise.resolve();}}}};
                window.__lunaStartPillDecision({scheme:'luna',supportsPlugins:true,
                    supportsArticles:true,supportsProducts:true,supportsMedia:true});
                void 0
                """)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertFalse(js.bool("!!document.getElementById(window.__lunaPillID)"), url)
            XCTAssertFalse(js.bool("!!document.getElementById(window.__lunaVideoOverlayID)"), url)
            XCTAssertEqual(js.string("JSON.stringify(calls)"), "[\"plugins.catalog\"]", url)
        }
    }

    func testRetailFixturesRunInSafariPluginBridge() {
        let source = SafariJSSource.read("LunaLibraries/Sources/LunaBundledPlugins/Plugins/web.js")
        for (fixture, url, currency) in [
            ("amazon-dp", "https://amazon.com.au/dp/X", "AUD"),
            ("target-nextdata", "https://target.com/p/test/-/A-123", "USD"),
            ("walmart-nextdata", "https://walmart.com/ip/123", "USD"),
            ("google-shopping-mova", "https://google.com/search?tbm=shop", "AUD")
        ] {
            js.load(html: SafariJSSource.read("LunaTests/Fixtures/Products/\(fixture).html"),
                    urlString: url, scripts: [SafariJSSource.read("LunaSafari/Resources/plugin_host.js")])
            js.evaluate("""
                window.plugin=new Function('var luna=LunaPluginHost.createBridge({capabilities:["html"]},function(){throw Error("Unexpected network");});'
                    + \(SafariJSTestHarness.jsString(source)) + ';return luna;')();
                window.answer=null; window.failure=null;
                plugin.__registeredHooks.ingest({url:location.href,page:{url:location.href,html:document.documentElement.outerHTML},reason:'save',context:'safari'})
                    .then(function(v){window.answer=v;},function(e){window.failure=String(e);}); void 0
                """)
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            XCTAssertEqual(js.string("answer && answer.kind"), "product", fixture)
            XCTAssertEqual(js.string("answer && answer.price.currency"), currency, fixture)
            XCTAssertTrue(js.bool("answer && Number(answer.price.amount)>0"), fixture)
            XCTAssertTrue(js.bool("failure===null"), fixture)
        }
    }
}
