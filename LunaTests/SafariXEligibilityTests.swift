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

    private func playFromMenu() {
        js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
        XCTAssertFalse(player, "Opening the pill menu must not open the player")
        js.evaluate("document.querySelector('[data-luna-action=playVideo]').click(); void 0")
        settle()
    }

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

    func testOnlyTheOpenedTweetsOwnVideoOffersPlayInTheMenu() {
        for url in [postURL, "https://mobile.twitter.com/alice/status/123", "https://x.com/i/web/status/123",
                    "https://x.com/alice/status/123/video/1"] {
            offer(tweet("456", media: "<video></video>") + tweet(media: "<div data-testid='videoPlayer'></div>"), at: url)
            XCTAssertTrue(pill, url)
            XCTAssertFalse(player, url)
            XCTAssertEqual(js.number("window.__resolveCalls"), 0)
            playFromMenu()
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
                self.js.evaluate("document.getElementById(window.__lunaPillID).click(); document.querySelector('[data-luna-action=openInLuna]').click(); void 0")
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
        XCTAssertFalse(player)
        playFromMenu()
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
        while !pill && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        playFromMenu()
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
        playFromMenu()
        js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); void 0")
        settle()
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        js.evaluate("document.getElementById(window.__lunaPillID).click(); document.querySelector('[data-luna-action=playVideo]').click(); void 0")
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
    private func offerCore(_ payload: String, context: String = "", deferred: Bool = false, failFirstSource: Bool = false, stallFirstSource: Bool = false, url: String = "https://x.com/ZetaPlusCG/status/2108409488554222078") {
        let plugin = SafariJSTestHarness.source("LunaLibraries/Sources/LunaBundledPlugins/Plugins/x.js")
        let host = SafariJSTestHarness.source("LunaSafari/Resources/plugin_host.js")
        js.load(html: "<html><body><p>Loading X</p>\(tweet("999", media: "<video></video>"))</body></html>",
                urlString: url,
                scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        js.evaluate("""
            window.__payload = \(payload);
            window.__sourceCalls = 0;
            window.__fetchCalls = 0;
            window.__queued = null;
            window.__catalogCache = {};
            window.__deferred = \(deferred ? "true" : "false");
            window.fetch = function () { return Promise.resolve({text: function () { return Promise.resolve(\(SafariJSTestHarness.jsString(host))); }}); };
            window.browser = {runtime: {getURL: function (p) { return p; }, sendMessage: function (m) {
                if (m.type === 'plugins.catalog') return Promise.resolve({stamp:'x1',plugins:[{id:'app.luna.x',hosts:['x.com'],produces:['media','article'],capabilities:['fetch']}]});
                if (m.type === 'plugins.source') {
                    window.__sourceCalls++;
                    if (\(stallFirstSource ? "true" : "false") && window.__sourceCalls === 1) return new Promise(function(){});
                    if (\(failFirstSource ? "true" : "false") && window.__sourceCalls === 1) return Promise.reject(new Error('Cold native bridge'));
                    return Promise.resolve({source:\(SafariJSTestHarness.jsString(plugin))}); }
                if (m.type === 'plugins.fetch') {
                    window.__fetchCalls++;
                    var response = {ok:true,status:200,text:JSON.stringify(window.__payload)};
                    if (window.__deferred) return new Promise(function (resolve) { window.__finishFetch = function () { resolve(response); }; });
                    return Promise.resolve(response);
                }
                if (m.type === 'plugins.queueModel') { window.__queued = m; return Promise.resolve({deepLink:'luna://pluginmodel?ret=safari'}); }
                return Promise.resolve({});
            }}, storage:{local:{get:function(){return Promise.resolve(window.__catalogCache);},set:function(value){window.__catalogCache=value;return Promise.resolve();}}}};
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
            XCTAssertFalse(player, payload)
            XCTAssertEqual(pill, expected, payload)
            if expected {
                playFromMenu()
                XCTAssertTrue(player, payload)
            }
        }
    }

    func testCoreVideoDismissalSettingsAndNavigationKeepTheirGates() {
        offerCore(coreVideoPayload)
        XCTAssertFalse(player)
        playFromMenu()
        XCTAssertTrue(player)
        js.evaluate("document.getElementById(window.__lunaVideoOverlayID)?.click(); void 0")
        settle()
        XCTAssertFalse(player)
        XCTAssertTrue(pill)
        js.evaluate("document.getElementById(window.__lunaPillID)?.click(); document.querySelector('[data-luna-action=playVideo]')?.click(); void 0")
        settle()
        XCTAssertTrue(player)
        js.evaluate("window.__payload = {tweet:{id:'456',text:'Just text'}}; history.pushState({}, '', '/alice/status/456'); void 0")
        settle()
        XCTAssertFalse(player)
        XCTAssertFalse(pill)
        // A fresh visit offers playback and waits for another explicit action.
        js.evaluate("window.__payload = \(coreVideoPayload); history.pushState({}, '', '/ZetaPlusCG/status/2108409488554222078'); void 0")
        settle()
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        playFromMenu()
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

    func testCoreRetriesAColdPluginBridgeWithoutRefreshing() {
        offerCore(coreVideoPayload, failFirstSource: true)
        XCTAssertFalse(pill)
        let deadline = Date().addingTimeInterval(4)
        while !pill && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(player)
        XCTAssertTrue(pill)
        XCTAssertEqual(js.number("window.__sourceCalls"), 2)
        playFromMenu()
        XCTAssertTrue(player)
    }

    func testCoreMenuSeparatesPlaybackOpenAndHideUntilRefresh() {
        offerCore(coreVideoPayload)
        js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
        XCTAssertFalse(player, "Opening the menu must not immediately start playback")
        XCTAssertEqual(js.string("Array.from(document.querySelectorAll('[role=menuitem]')).map(x => x.textContent).join('|')"), "Play Video|Open in Luna|Hide")
        XCTAssertEqual(js.number("document.getElementById(window.__lunaPillID).getBoundingClientRect().width"), 52)
        XCTAssertEqual(js.number("document.getElementById(window.__lunaPillID).getBoundingClientRect().height"), 52)
        XCTAssertLessThan(js.number("document.getElementById('luna-action-menu').getBoundingClientRect().bottom"),
                          js.number("document.getElementById(window.__lunaPillID).getBoundingClientRect().top"),
                          "The menu should anchor immediately above the circle")
        js.evaluate("document.querySelector('[data-luna-action=hideLuna]').click(); void 0")
        XCTAssertFalse(pill)
        XCTAssertFalse(player)
        js.evaluate("history.pushState({}, '', '/other/status/456'); void 0")
        settle()
        js.evaluate("history.pushState({}, '', '/ZetaPlusCG/status/2108409488554222078'); void 0")
        settle()
        XCTAssertFalse(pill, "Hide lasts until a document refresh")
        XCTAssertFalse(player)
        offerCore(coreVideoPayload)
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
    }

    func testCoreOpenInLunaQueuesTheAlreadyResolvedVideoWithoutPlaying() {
        offerCore(coreVideoPayload)
        XCTAssertFalse(player)
        let link = js.awaitAppSchemeNavigation {
            self.js.evaluate("document.getElementById(window.__lunaPillID).click(); document.querySelector('[data-luna-action=openInLuna]').click(); void 0")
        }
        XCTAssertTrue(link == "luna://pluginmodel?ret=safari")
        XCTAssertFalse(player)
        XCTAssertEqual(js.number("window.__fetchCalls"), 1, "Open should reuse the resolved Model")
        XCTAssertEqual(js.string("window.__queued.id"), "app.luna.x")
        XCTAssertTrue(js.string("window.__queued.model")?.contains("movie.mp4") == true)
    }

    func testReportedPostOpensCorePlayerUsingItsResolvedVideo() {
        // The reported post's media shape, without relying on a live network.
        offerCore("{tweet:{id:'2109373525043905019',media:{all:[{type:'video',url:'https://video.twimg.com/amplify_video/2109373480454012928/vid/avc1/1280x720/Cac_MDJjXCdgxNKa.mp4?tag=29'}]}}}",
                  url: "https://x.com/lilifying/status/2109373525043905019?s=20")
        XCTAssertFalse(player)
        playFromMenu()
        XCTAssertTrue(player)
        XCTAssertTrue(pill)
        XCTAssertTrue(js.string("document.getElementById(window.__lunaVideoOverlayID)?.querySelector('video')?.src")?.contains("2109373480454012928") == true)
    }

    func testCoreArticleMenuOffersOpenAndHideWithoutPlay() {
        offerCore("{tweet:{id:'2108409488554222078',text:'" + String(repeating: "Long article text. ", count: 50) + "'}}")
        XCTAssertTrue(pill)
        XCTAssertFalse(player)
        js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
        XCTAssertFalse(js.bool("!!document.querySelector('[data-luna-action=playVideo]')"))
        XCTAssertEqual(js.string("Array.from(document.querySelectorAll('[role=menuitem]')).map(x=>x.textContent).join('|')"), "Open in Luna|Hide")
        js.evaluate("document.dispatchEvent(new KeyboardEvent('keydown', {key:'Escape',bubbles:true})); void 0")
        XCTAssertFalse(js.bool("!!document.getElementById('luna-action-menu')"))
        XCTAssertEqual(js.string("document.getElementById(window.__lunaPillID).getAttribute('aria-expanded')"), "false")
    }

    func testCoreRecoversFromAStalledSourceRequestWithoutRefreshing() {
        offerCore(coreVideoPayload, stallFirstSource: true)
        XCTAssertFalse(pill)
        let deadline = Date().addingTimeInterval(12)
        while !pill && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertFalse(player)
        XCTAssertTrue(pill)
        XCTAssertEqual(js.number("window.__sourceCalls"), 2)
        playFromMenu()
        XCTAssertTrue(player)
    }

}
