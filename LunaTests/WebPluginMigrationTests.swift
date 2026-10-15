import XCTest
import JavaScriptCore
import LunaPluginUI
import LunaStorage
import LunaModels
import LunaPluginKit
import LunaPluginIngest
import LunaIngest
import LunaReaderUI

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

    func testDailyBeastAstroContinuationDoesNotNeedArchiveOrBrowserInJSC() async throws {
        try load("publisher-access")
        let url = "https://www.thedailybeast.com/animated-pete-hegseth-snaps-at-press-during-wild-pentagon-briefing"
        let html = try String(contentsOf: root.appendingPathComponent("LunaTests/Fixtures/Plugins/dailybeast-astro.html"), encoding: .utf8)
        runner.fetcher.respond(to: url, body: html)
        let teaser = """
        <html><head><script type="application/ld+json">{"@type":"NewsArticle","isAccessibleForFree":false}</script></head>
        <body><article id="article-content"><p data-block-type="text">Only the opening is available.</p>
        <div class="tdb-paywall">Subscribe to read.</div></article></body></html>
        """
        // A captured full page, initial fetch, and teaser followed by a full
        // probe must all finish without archives or a deferred browser.
        for mode in 0...2 {
            let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
                argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                    page: mode == 1 ? nil : .init(url: url, html: mode == 0 ? html : teaser, source: "fetch"),
                    reason: .save, context: .share), timeout: 2, as: PluginIngestAnswer.self)
            guard case let .model(.article(article)) = answer else { return XCTFail("No article") }
            XCTAssertEqual(article.title, "Daily Beast regression")
            XCTAssertEqual(article.author, "Fixture Reporter")
            for n in 1...6 { XCTAssertTrue(article.html.contains("Paragraph \(n).")) }
            XCTAssertTrue(article.html.contains("fixture.jpg"))
            XCTAssertTrue(article.html.contains("inline source"))
            XCTAssertFalse(article.html.contains("must not appear"))
            XCTAssertFalse(article.html.contains("Subscribe to read"))
        }
        XCTAssertTrue(runner.fetcher.requests.count >= 2)
        XCTAssertTrue(runner.fetcher.requests.allSatisfy { $0.url.absoluteString == url })
    }

    func testNewYorkerKeepsOpeningAndPaywallMarkedProseInJSC() async throws {
        try load("publisher-access")
        let url = "https://www.newyorker.com/magazine/2026/10/05/cookie-monster-tries-to-meet-his-ai-mandate"
        let html = try String(contentsOf: root.appendingPathComponent("LunaTests/Fixtures/Plugins/newyorker-paywall-paragraphs.html"), encoding: .utf8)
        runner.fetcher.respond(to: url, body: html)
        for capturedPage in [true, false] {
            let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
                argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                    page: capturedPage ? .init(url: url, html: html, source: "safari") : nil,
                    reason: .save, context: .share), timeout: 2, as: PluginIngestAnswer.self)
            guard case let .model(.article(article)) = answer else { return XCTFail("No article") }
            XCTAssertEqual(article.title, "New Yorker regression")
            XCTAssertEqual(article.author, "Fixture Reporter")
            XCTAssertTrue(article.html.hasPrefix("<p class=\"has-dropcap body dropcap has-dropcap__lead-standard-heading\">Me resident cookie expert"))
            XCTAssertEqual(article.html.components(separatedBy: "<p ").count - 1, 22)
            var remainder = article.html[...]
            for n in 2...22 {
                let marker = String(format: "Paragraph %02d.", n)
                guard let range = remainder.range(of: marker) else { return XCTFail("Missing or reordered \(marker)") }
                remainder = remainder[range.upperBound...]
            }
            XCTAssertTrue(article.html.contains("inline source"))
            XCTAssertTrue(article.html.contains("fixture.jpg"))
            XCTAssertFalse(article.html.contains("must not appear"))
        }
        XCTAssertEqual(runner.fetcher.requests.map { $0.url.absoluteString }, [url])
    }

    func testNewYorkerCapturedLivePage() async throws {
        guard ProcessInfo.processInfo.environment["LUNA_NEWYORKER_LIVE_FIXTURE"] == "1" else {
            throw XCTSkip("Opt-in verification against the freshly fetched New Yorker page")
        }
        try load("web")
        let url = "https://www.newyorker.com/magazine/2026/10/05/cookie-monster-tries-to-meet-his-ai-mandate"
        runner.fetcher.respond(to: url, body: try String(contentsOfFile: "/tmp/luna-newyorker-cookie.html", encoding: .utf8))
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.web",
            argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                page: nil, reason: .save, context: .app), as: PluginIngestAnswer.self)
        guard case let .model(.article(article)) = answer else { return XCTFail("Live page did not produce an article") }
        XCTAssertTrue(article.html.hasPrefix("<p class=\"has-dropcap body dropcap has-dropcap__lead-standard-heading\">Me resident cookie expert"))
        XCTAssertEqual(article.html.components(separatedBy: "<p ").count - 1, 22)
        XCTAssertTrue(article.html.contains("not actual monster"), "The ending must also survive")
        XCTAssertEqual(runner.fetcher.requests.count, 1)
    }

    func testNewYorkerNormalPluginWalkPersistsTheOpening() async throws {
        let scope = PluginAdopterScope()
        defer { scope.restore() }
        PluginModelAdopters.article = ArticleModelAdopter()
        try load("web")
        try load("publisher-access")
        let url = URL(string: "https://www.newyorker.com/magazine/2026/10/05/cookie-monster-tries-to-meet-his-ai-mandate")!
        let html = try String(contentsOf: root.appendingPathComponent("LunaTests/Fixtures/Plugins/newyorker-paywall-paragraphs.html"), encoding: .utf8)
        runner.fetcher.respond(to: url.absoluteString, body: html)
        let stage = PluginIngestStage(invoker: runner.runtime, processKind: .app)
        let result = await stage.run(IngestInput(url: url, source: .manual), fetcher: MockArticleFetcher())
        guard case let .outcome(.article(content, _), owner) = result else { return XCTFail("No article from the normal plugin walk") }
        XCTAssertEqual(owner, "app.luna.web", "The first eligible plugin must preserve the opening before publisher recovery runs")
        let saves = SavesStore(containerURL: runner.containerURL.appendingPathComponent("save-regression"))
        let item = saves.add(urlString: url.absoluteString)
        _ = saves.saveContent(content, for: item)
        let saved = try XCTUnwrap(saves.item(withID: item.id))
        let stored = try XCTUnwrap(saves.content(for: saved))
        let paragraphs = stored.blocks.filter { $0.kind == .paragraph }
        XCTAssertEqual(paragraphs.count, 22)
        XCTAssertTrue(paragraphs.first?.text.hasPrefix("Me resident cookie expert") == true)
        XCTAssertTrue(paragraphs[1].text.hasPrefix("Matt here to"))
        XCTAssertFalse(stored.blocks.contains { $0.text.contains("must not appear") })
        XCTAssertEqual(runner.fetcher.requests.count, 1)
    }

    func testPublisherReadsSpecificTimeMapSnapshotWithoutOpeningABrowser() async throws {
        try load("publisher-access")
        let url = "https://www.wsj.com/tech/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-160eec6b"
        let snapshot = "https://archive.md/20261015021530/"+url
        runner.fetcher.respond(to: url, body: "<article><p>Subscribe to read</p></article>")
        runner.fetcher.respond(to: "https://archive.is/timemap/"+url, body: """
            <http://archive.md/timegate/\(url)>; rel="timegate",
            <http://archive.md/20261015021530/\(url)>; rel="first last memento"; datetime="Thu, 15 Oct 2026 02:15:30 GMT"
            """)
        runner.fetcher.respond(to: snapshot, body: """
            <html><head><title>Recovered WSJ</title></head><body><div id="CONTENT">
            <p>\(String(repeating: "Full archived reporting on trade secrets. ", count: 100))</p>
            </div></body></html>
            """)
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
            argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                                           page: nil, reason: .save, context: .app), as: PluginIngestAnswer.self)
        guard case let .model(.article(article)) = answer else { return XCTFail("No article from TimeMap snapshot") }
        XCTAssertTrue(article.html.contains("Full archived reporting"))
        XCTAssertTrue(runner.fetcher.requests.contains { $0.url.absoluteString == snapshot })
    }

    func testWSJRecoversCanonicalSyndicationWhenArchiveCapturedOnlyBotGate() async throws {
        try await assertWSJSyndication(canonicalMatches: true)
    }

    func testWSJRejectsSyndicationForADifferentCanonicalStory() async throws {
        try await assertWSJSyndication(canonicalMatches: false)
    }

    private func assertWSJSyndication(canonicalMatches: Bool) async throws {
        try load("publisher-access")
        let url = "https://www.wsj.com/tech/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-160eec6b"
        let copy = "https://www.livemint.com/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-11792030183031.html"
        let snapshot = "https://archive.md/20261015021530/" + url
        runner.fetcher.respond(to: url, body: "<article><p>Subscribe to read</p></article>")
        runner.fetcher.respond(to: "https://archive.is/timemap/" + url,
                               body: "<\(snapshot)>; rel=\"last memento\"")
        runner.fetcher.respond(to: snapshot, body: "<div id=\"CONTENT\">Please enable JS and disable any ad blocker</div>")
        runner.fetcher.respond(to: "https://www.livemint.com/wsj", body: "<a href=\"\(copy)\">Syndicated story</a>")
        let canonical = canonicalMatches ? url : "https://www.wsj.com/tech/ai/different-story-12345678"
        runner.fetcher.respond(to: copy, body: """
            <html><head><title>Syndicated reporting</title><link rel="canonical" href="\(canonical)">
            <script type="application/ld+json">{"@type":"NewsArticle","articleBody":"\(String(repeating: "Opening paragraph. ", count: 20))"}</script></head>
            <body><div id="mainArea"><div class="storyParagraph"><p>Opening paragraph.</p></div>
            <div class="paywall-slot"><div class="storyParagraph"><p>\(String(repeating: "Complete syndicated reporting. ", count: 150))</p></div></div></div></body></html>
            """)
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
            argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                page: nil, reason: .save, context: .app), as: PluginIngestAnswer.self)
        if canonicalMatches {
            guard case let .model(.article(article)) = answer else { return XCTFail("No syndicated article") }
            XCTAssertTrue(article.html.contains("Complete syndicated reporting"))
            XCTAssertEqual(article.baseURL?.absoluteString, copy)
        } else {
            guard case .declined = answer else { return XCTFail("Unrelated canonical accepted") }
        }
    }

    func testWSJCapturedLivePublisherPages() async throws {
        guard ProcessInfo.processInfo.environment["LUNA_WSJ_LIVE_FIXTURES"] == "1" else {
            throw XCTSkip("Opt-in verification against freshly fetched publisher pages")
        }
        try load("publisher-access")
        let url = "https://www.wsj.com/tech/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-160eec6b"
        let copy = "https://www.livemint.com/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-11792030183031.html"
        for (address, file) in [(url, "original"), ("https://www.livemint.com/wsj", "index"), (copy, "copy")] {
            runner.fetcher.respond(to: address, body: try String(contentsOfFile: "/tmp/luna-wsj-" + file + ".html", encoding: .utf8))
        }
        let answer: PluginIngestAnswer? = await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
            argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                page: nil, reason: .save, context: .app), as: PluginIngestAnswer.self)
        guard case let .model(.article(article)) = answer else { return XCTFail("Live pages failed to recover article") }
        XCTAssertTrue(article.html.contains("San Francisco playground"))
        XCTAssertTrue(article.html.contains("foundation models"), "the end of the article must be present")
        XCTAssertEqual(article.baseURL?.absoluteString, copy)
    }

    @MainActor
    private final class WSJArchiveBrowser: PluginBrowserPresenting {
        var urls: [String] = []
        var stages: [String] = []
        var submittedURL: String?
        let html: String
        init(html: String) { self.html = html }
        func presentBrowserStep(_ request: PluginBrowserRequest, pluginID: String) async -> PluginBrowserResult? {
            urls.append(request.url.absoluteString)
            let context = JSContext()!
            // archive.li's real CAPTCHA has the site name as its title, and
            // its widget is #g-recaptcha. The title-only probe hid it forever.
            context.evaluateScript("""
                var location={pathname:'/snapshot'};
                var document={title:'archive.li', body:{innerText:'Why do I have to complete a CAPTCHA?'},
                  querySelectorAll:()=>[], querySelector:s=>s.includes('#g-recaptcha')?{}:null};
                """)
            stages.append(context.evaluateScript(request.detect)?.toString() ?? "")
            // A short teaser article comes before #CONTENT; an ad's CAPTCHA
            // remains after the real article appears. Full content must win.
            context.evaluateScript("""
                document.body.innerText='Archived article';
                document.querySelectorAll=()=>[{innerText:'Teaser'}, {innerText:'Full reporting. '.repeat(160)}];
                """)
            stages.append(context.evaluateScript(request.detect)?.toString() ?? "")
            context.evaluateScript("""
                var window={};location.pathname='/';
                var input={value:'',form:{submit:()=>{window.submitted=input.value;}}};
                document.querySelector=s=>s==='input[name="url"]'?input:null;
                document.querySelectorAll=()=>[];
                """)
            stages.append(context.evaluateScript(request.detect)?.toString() ?? "")
            submittedURL = context.evaluateScript("window.submitted")?.toString()
            return PluginBrowserResult(url: "https://archive.li/fixture", html: html,
                                       title: "Recovered WSJ", cookieHeader: "", cookies: [])
        }
    }

    @MainActor
    func testWSJUsesArchiveRevealsCaptchaAndExtractsSnapshotBeyondTeasers() async throws {
        try load("publisher-access")
        let url = "https://www.wsj.com/tech/ai/ai-companies-play-cat-and-mouse-with-secret-stealing-spies-160eec6b"
        let saves = SavesStore(containerURL: runner.containerURL.appendingPathComponent("browser-saves"))
        let saved = saves.add(urlString: url)
        let browser = WSJArchiveBrowser(html: """
            <html><head><title>Recovered WSJ</title></head><body>
            <article><p>Unrelated teaser must not appear</p></article>
            <div id="CONTENT"><div><h1>Recovered WSJ</h1>
            <div>\(String(repeating: "Complete article reporting about protecting trade secrets. ", count: 100))</div>
            <div>Final paragraph of recovered reporting.</div></div></div></body></html>
            """)
        runner.capabilities.register(PluginBrowserBridge(
            processKind: .app, scheduler: runner.runtime,
            requests: PluginBrowserRequestStore(saves: saves), presenter: browser))
        // Registering a new capability requires reloading the plugin context.
        _ = runner.runtime.loadAll()
        runner.fetcher.respond(to: url, body: "<article><p>Subscribe to read</p></article>")
        let answer: PluginIngestAnswer? = await PluginIngestScope.run(
            saveID: saved.id, pluginID: "app.luna.publisher-access") {
                await runner.invoke(.ingest, pluginID: "app.luna.publisher-access",
                    argument: PluginIngestHookInput(url: url, claim: .init(kind: .article, itemID: nil),
                        page: nil, reason: .save, context: .app, saveID: saved.id.uuidString),
                    timeout: 5, as: PluginIngestAnswer.self)
            }
        XCTAssertEqual(browser.urls, ["https://archive.is/"])
        XCTAssertEqual(browser.stages, ["challenge", "done", "wait"])
        XCTAssertEqual(browser.submittedURL, url, "the homepage submits the article without typing")
        guard case let .model(.article(article)) = answer else { return XCTFail("No recovered WSJ article") }
        XCTAssertTrue(article.html.contains("Final paragraph"))
        XCTAssertFalse(article.html.contains("Unrelated teaser"))
        XCTAssertEqual(article.baseURL?.absoluteString, url)
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
