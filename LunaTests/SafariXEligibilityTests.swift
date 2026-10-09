import XCTest

@MainActor
final class SafariXEligibilityTests: XCTestCase {
    private lazy var js = SafariJSTestHarness(self)
    private let postURL = "https://x.com/alice/status/123"

    private func tweet(_ id: String = "123", text: String = "An ordinary tweet", media: String = "") -> String {
        """
        <article data-testid="tweet"><a href="/alice/status/\(id)"><time>Today</time></a>
        <div data-testid="tweetText">\(text)</div>\(media)</article>
        """
    }

    private func offer(_ body: String, at url: String? = nil, context: String = "") {
        js.load(html: "<html><head><meta property='og:video' content='https://example.com/stale.mp4'></head><body>\(body)</body></html>",
                urlString: url ?? postURL, scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        js.evaluate("""
            window.__resolveCalls = 0;
            window.__pluginCalls = 0;
            window.browser = { runtime: { sendMessage: function () {
                window.__pluginCalls++;
                return new Promise(function (resolve) { window.__finishCatalog = resolve; });
            } } };
            window.__lunaSetResolveMediaRequest(function () {
                window.__resolveCalls++;
                return Promise.resolve({ assets: [
                    { url: "https://cdn.example.com/v.mp4", kind: "video" }
                ] });
            });
            window.__lunaStartPillDecision({scheme: "luna", supportsArticles: true,
                supportsProducts: true, supportsMedia: true \(context)});
            "offered"
            """)
        _ = js.evaluate("void 0")
    }

    private var pill: Bool { js.bool("!!document.getElementById(window.__lunaPillID)") }
    private var player: Bool { js.bool("!!document.getElementById(window.__lunaVideoOverlayID)") }

    private func settle() { RunLoop.current.run(until: Date().addingTimeInterval(0.7)) }

    func testFeedsProfilesSearchAndMalformedStatusesNeverShowControlsEvenWithVideo() {
        for path in ["/", "/home", "/explore", "/search?q=video", "/alice", "/notifications",
                     "/alice/status/nope", "/settings/alice/status/123", "/alice/status/123/likes"] {
            offer(tweet(media: "<video></video>"), at: "https://x.com" + path,
                  context: ", supportsPlugins: true")
            XCTAssertFalse(pill, path)
            XCTAssertFalse(player, path)
            XCTAssertEqual(js.number("window.__resolveCalls"), 0)
            XCTAssertEqual(js.number("window.__pluginCalls"), 1)
        }
    }

    func testShortTextAndPhotosIgnoreVideoAndLongTextInRepliesQuotesAndMetadata() {
        let quote = "<div role='link'>\(tweet("999", text: String(repeating: "Long reply. ", count: 100), media: "<video></video>"))</div>"
        offer(tweet(media: "<img src='photo.jpg'>" + quote) + tweet("456", media: "<video></video>"))
        settle()
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        XCTAssertEqual(js.number("window.__resolveCalls"), 0)
        // A quoted timestamp alone cannot identify the primary tweet.
        offer(tweet("456", media: "<div role='link'>\(tweet(media: "<video></video>"))</div>"))
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
    }

    func testOnlyTheOpenedTweetsOwnVideoOpensThePlayer() {
        for url in [postURL, "https://mobile.twitter.com/alice/status/123", "https://x.com/i/web/status/123",
                    "https://x.com/alice/status/123/video/1"] {
            offer(tweet("456", media: "<video></video>") + tweet(media: "<div data-testid='videoPlayer'></div>"), at: url)
            XCTAssertTrue(pill, url)
            XCTAssertTrue(player, url)
            XCTAssertEqual(js.number("window.__resolveCalls"), 1)
        }
    }

    func testLongTextThreadAndArticleOfferReaderWithoutPlayer() {
        for content in [tweet(text: String(repeating: "a", count: 281)), tweet(text: "1/4 A thread begins here"),
                        tweet(media: "<div data-testid='twitterArticleRichTextView'>An article</div>"),
                        tweet(media: "<button data-testid='tweet-text-show-more-link'>Show more</button>")] {
            offer(content)
            XCTAssertTrue(pill)
            XCTAssertFalse(player)
            XCTAssertEqual(js.number("window.__resolveCalls"), 0)
            let link = js.awaitAppSchemeNavigation {
                self.js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
            }
            XCTAssertTrue(link?.hasPrefix("luna://read?url=") == true)
            XCTAssertFalse(player)
        }
        offer(tweet(text: String(repeating: "a", count: 280)))
        XCTAssertFalse(pill)
        offer(tweet(text: String(repeating: "😀", count: 280)))
        XCTAssertFalse(pill)
    }

    func testHydrationAndSoftNavigationReevaluateOwnedContentAndCloseStalePlayer() {
        offer("<p>Loading</p>", at: "https://x.com/home")
        js.evaluate("history.pushState({}, '', '/alice/status/123'); document.body.innerHTML = \(SafariJSTestHarness.jsString(tweet())); void 0")
        settle()
        XCTAssertFalse(pill)
        js.evaluate("document.querySelector('article').insertAdjacentHTML('beforeend', '<video></video>'); void 0")
        settle()
        XCTAssertTrue(pill)
        XCTAssertTrue(player)
        js.evaluate("history.pushState({}, '', '/home'); void 0")
        settle()
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        // Old video stays in the DOM during navigation to another status.
        js.evaluate("history.pushState({}, '', '/alice/status/456'); void 0")
        settle()
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        js.evaluate("document.body.innerHTML = \(SafariJSTestHarness.jsString(tweet("456", media: "<video></video>"))); void 0")
        let deadline = Date().addingTimeInterval(3)
        while !player && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(player)
    }

    func testPendingPluginDecisionCannotPresentAfterNavigation() {
        offer(tweet(media: "<video></video>"), context: ", supportsPlugins: true")
        XCTAssertEqual(js.number("window.__pluginCalls"), 1)
        XCTAssertFalse(player)
        js.evaluate("history.pushState({}, '', '/home'); window.__finishCatalog({plugins: []}); void 0")
        settle()
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        XCTAssertEqual(js.number("window.__resolveCalls"), 0)
    }

    func testDismissalAndSettingsAreRespected() {
        offer(tweet(media: "<video></video>"))
        js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); void 0")
        settle()
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
        XCTAssertTrue(player)
        offer(tweet(media: "<video></video>"), context: ", videoPlayer: false")
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        offer(tweet(media: "<video></video>"), context: ", mode: 'never'")
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        offer(tweet(text: String(repeating: "a", count: 600)), context: ", supportsArticles: false")
        XCTAssertFalse(pill)
    }
    /// Use the same host table as Safari: without it, isXHost() is false and
    /// the old DOM veto is never exercised by these plugin-path tests.
    private func offerCore(_ payload: String, context: String = "", deferred: Bool = false) {
        let plugin = SafariJSTestHarness.source("LunaLibraries/Sources/LunaBundledPlugins/Plugins/x.js")
        let host = SafariJSTestHarness.source("LunaSafari/Resources/plugin_host.js")
        js.load(html: "<html><body><p>Loading X</p>\(tweet("999", media: "<video></video>"))</body></html>",
                urlString: "https://x.com/ZetaPlusCG/status/2108409488554222078",
                scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        js.evaluate("""
            window.__payload = \(payload);
            window.__deferred = \(deferred ? "true" : "false");
            window.fetch = function () { return Promise.resolve({text: function () { return Promise.resolve(\(SafariJSTestHarness.jsString(host))); }}); };
            window.browser = {runtime: {getURL: function (p) { return p; }, sendMessage: function (m) {
                if (m.type === 'plugins.catalog') return Promise.resolve({plugins:[{id:'app.luna.x',hosts:['x.com'],produces:['media','article'],capabilities:['fetch']}]});
                if (m.type === 'plugins.source') return Promise.resolve({source:\(SafariJSTestHarness.jsString(plugin))});
                if (m.type === 'plugins.fetch') {
                    var response = {ok:true,status:200,text:JSON.stringify(window.__payload)};
                    if (window.__deferred) return new Promise(function (resolve) { window.__finishFetch = function () { resolve(response); }; });
                    return Promise.resolve(response);
                }
                return Promise.resolve({});
            }}};
            window.__lunaStartPillDecision({scheme:'luna',supportsPlugins:true,supportsMedia:true,supportsArticles:true \(context)});
            void 0
            """)
        settle()
    }

    private var coreVideoPayload: String {
        "{tweet:{id:'2108409488554222078',text:'THAT CRIT ANIMATION MAN!',media:{all:[{type:'video',url:'https://cdn.example.com/movie.mp4'}]}}}"
    }

    func testCoreResolvesVideoWithoutTweetDOMAndDoesNotOpenTextOrWrongStatus() {
        for (payload, expected) in [
            (coreVideoPayload, true),
            ("{tweet:{id:'2108409488554222078',text:'A short post',media:{all:[]}}}", false),
            ("{tweet:{id:'2108409488554222078',media:{all:[{type:'photo',url:'https://cdn.example.com/photo.jpg'}]}}}", false),
            ("{tweet:{id:'999',media:{all:[{type:'video',url:'https://cdn.example.com/movie.mp4'}]}}}", false),
            ("{thread:[{id:'2108409488554222078',text:'Text only'},{id:'999',media:{all:[{type:'video',url:'https://cdn.example.com/movie.mp4'}]}}]}", false)
        ] {
            offerCore(payload)
            XCTAssertEqual(player, expected, payload)
            XCTAssertEqual(pill, expected, payload)
        }
    }

    func testCoreVideoDismissalSettingsAndNavigationKeepTheirGates() {
        offerCore(coreVideoPayload)
        XCTAssertTrue(player)
        js.evaluate("document.getElementById(window.__lunaVideoOverlayID)?.click(); void 0")
        settle()
        XCTAssertFalse(player)
        XCTAssertTrue(pill)
        js.evaluate("document.getElementById(window.__lunaPillID)?.click(); void 0")
        settle()
        XCTAssertTrue(player)
        js.evaluate("window.__payload = {tweet:{id:'456',text:'Just text'}}; history.pushState({}, '', '/alice/status/456'); void 0")
        settle()
        XCTAssertFalse(player)
        XCTAssertFalse(pill)
        // A fresh visit to a video post still opens automatically.
        js.evaluate("window.__payload = \(coreVideoPayload); history.pushState({}, '', '/ZetaPlusCG/status/2108409488554222078'); void 0")
        settle()
        XCTAssertTrue(player)
        offerCore(coreVideoPayload, context: ", videoPlayer:false")
        XCTAssertFalse(player)
        XCTAssertTrue(pill)
        offerCore(coreVideoPayload, context: ", mode:'never'")
        XCTAssertFalse(player)
        XCTAssertFalse(pill)
    }

    func testCoreLateVideoResolutionCannotOpenOverANewPost() {
        offerCore(coreVideoPayload, deferred: true)
        XCTAssertFalse(player)
        XCTAssertTrue(js.bool("typeof window.__finishFetch === 'function'"))
        // Resolve in the interval before the URL watcher fires.
        js.evaluate("history.pushState({}, '', '/alice/status/456'); window.__finishFetch(); void 0")
        settle()
        XCTAssertFalse(player)
        XCTAssertFalse(pill)
    }

}
