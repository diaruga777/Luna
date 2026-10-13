//
//  SafariMediaPillTests.swift
//  LunaTests
//

import XCTest

/// The route from a media page to the in-page player: which target a recognized
/// platform page earns and how its menu requires an explicit Play Video action.
///
/// `SafariVideoOverlayTests` drives `__lunaPresentVideoOverlay` directly with a
/// hand-built hand-off, so it proves what the overlay does once open and nothing
/// about how the user gets there. This suite runs the real decision
/// (`offerLunaButton` -> `videoOverlayTargetFor` -> `injectLunaButton`)
/// against each platform host that reaches it.
@MainActor
final class SafariMediaPillTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    /// A post page whose subject is a video.
    nonisolated private static let videoPost = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:video" content="https://cdn.example.com/v.mp4">
        </head><body style="margin:0"><article data-testid="tweet"><a href="/someone/status/1234567890"><time>Today</time></a><video></video></article></body></html>
        """

    /// A reel as Instagram actually serves it: `og:type` "article", a JPG as the
    /// only media meta, and no `og:video` / `twitter:player` anywhere.
    private static let instagramReelAsServed = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:type" content="article">
        <meta property="og:image" content="https://scontent.cdninstagram.com/cover.jpg">
        </head><body style="margin:0"><p>caption</p></body></html>
        """

    /// A recognized platform page with NO video signal: a bare host / feed shell.
    private static let noVideoSignal = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        </head><body style="margin:0"><p>feed</p></body></html>
        """

    /// One per platform branch of `recognizedPlatformPage` that routes through
    /// `videoOverlayTargetFor` (Reddit deliberately does not — see below).
    private static let mediaPages = [
        "https://www.facebook.com/reel/1053951533795092",
        "https://www.instagram.com/reel/ABC123/",
        "https://www.tiktok.com/@someone/video/7000000000000000000",
        "https://x.com/someone/status/1234567890",
        "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
    ]

    // MARK: - Harness

    /// Loads `urlString` with the platform table injected (as `background.js`
    /// does), then runs the whole pill decision for a media-handling host with
    /// the native resolve stubbed to answer `assets`.
    private func offer(
        _ html: String = SafariMediaPillTests.videoPost, at urlString: String,
        assets: String = "[{ url: \"https://cdn.example.com/v.mp4\", kind: \"video\" }]"
    ) {
        js.load(
            html: html, urlString: urlString,
            scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        _ = js.evaluate("""
            window.__resolveCalls = 0;
            window.__lunaSetResolveMediaRequest(function () {
                window.__resolveCalls++;
                return Promise.resolve({ assets: \(assets) });
            });
            window.__lunaOfferLunaButton({ scheme: "lunadownloader", supportsMedia: true });
            "offered"
            """)
    }

    private func pillExists() -> Bool {
        js.bool("!!document.getElementById(window.__lunaPillID)")
    }

    private func overlayExists() -> Bool {
        js.bool("!!document.getElementById(window.__lunaVideoOverlayID)")
    }

    /// Polls for hydration and asynchronous media resolution.
    @discardableResult
    private func eventually(_ predicate: String, within seconds: TimeInterval = 2) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if js.bool(predicate) { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        return js.bool(predicate)
    }

    private func waitForOverlay(within seconds: TimeInterval = 2) -> Bool {
        eventually("!!document.getElementById(window.__lunaVideoOverlayID)", within: seconds)
    }

    private func dismissOverlay() {
        _ = js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); \"closed\"")
    }

    private func tapPill() {
        _ = js.evaluate("""
            document.getElementById(window.__lunaPillID).click();
            var action = document.querySelector('[data-luna-action=playVideo]') || document.querySelector('[data-luna-action=openInLuna]');
            action.click(); "tapped"
            """)
        // The resolve settles on a microtask; a second round trip is past it.
        _ = js.evaluate("void 0")
    }

    // MARK: - Playback requires the menu action

    func testEveryMediaPageWaitsForPlayVideoInThePillMenu() {
        for page in Self.mediaPages {
            offer(at: page)
            XCTAssertTrue(pillExists(), page)
            XCTAssertFalse(waitForOverlay(within: 0.6), page)
            XCTAssertEqual(js.number("window.__resolveCalls"), 0, page)
            _ = js.evaluate("document.getElementById(window.__lunaPillID).click(); void 0")
            XCTAssertTrue(js.bool("!!document.querySelector('[data-luna-action=playVideo]')"), page)
            XCTAssertFalse(overlayExists(), "the pill should only open its menu on \(page)")
            XCTAssertEqual(js.number("window.__resolveCalls"), 0, page)
            _ = js.evaluate("document.querySelector('[data-luna-action=playVideo]').click(); void 0")
            XCTAssertTrue(waitForOverlay(), page)
            XCTAssertEqual(js.number("window.__resolveCalls"), 1, page)
            XCTAssertEqual(js.string("document.getElementById(window.__lunaVideoOverlayID).querySelector('video').getAttribute('src')"),
                           "https://cdn.example.com/v.mp4", page)
        }
    }

    func testThePillRemainsAvailableBehindTheRequestedPlayer() {
        offer(at: Self.mediaPages[0])
        tapPill()
        XCTAssertTrue(waitForOverlay())
        XCTAssertTrue(pillExists())
    }

    /// A reel can offer Play Video without waiting for Instagram's video DOM.
    func testAnInstagramReelRequiresPlayEvenWithNoVideoMetadata() {
        offer(Self.instagramReelAsServed, at: "https://www.instagram.com/reel/ABC123/")
        XCTAssertTrue(pillExists())
        XCTAssertFalse(waitForOverlay(within: 0.6))
        tapPill()
        XCTAssertTrue(waitForOverlay())
    }

    /// …and `/p/`, which carries both photos and videos, stays on the heuristics:
    /// a page that looks like a static image post earns no pill and no panel.
    func testAnInstagramPhotoPostGetsNeitherPillNorPlayer() {
        offer(Self.instagramReelAsServed, at: "https://www.instagram.com/p/ABC123/")
        XCTAssertFalse(pillExists(), "a static-image post is not proactively suggested")
        XCTAssertFalse(waitForOverlay(within: 0.5))
    }

    func testAVideoThatHydratesLaterOffersThePillWithoutOpeningThePlayer() {
        offer(Self.noVideoSignal, at: "https://x.com/someone/status/1234567890")
        XCTAssertFalse(overlayExists())
        _ = js.evaluate("""
            document.body.innerHTML = '<article data-testid="tweet"><a href="/someone/status/1234567890"><time>Today</time></a><video></video></article>';
            "hydrated"
            """)
        XCTAssertTrue(eventually("!!document.getElementById(window.__lunaPillID)"))
        XCTAssertFalse(waitForOverlay(within: 1))
        XCTAssertEqual(js.number("window.__resolveCalls"), 0)
        tapPill()
        XCTAssertTrue(waitForOverlay())
    }

    /// X feeds never earn a pill or player, even before they hydrate.
    func testAnXFeedOffersNeitherPillNorPlayer() {
        offer(Self.noVideoSignal, at: "https://x.com/home")
        XCTAssertFalse(pillExists(), "an X feed is not an individual tweet")
        XCTAssertFalse(waitForOverlay(within: 0.5), "no video on the page, no panel over it")
    }

    // MARK: - Dismissal

    /// Closing it is the user saying "not this page". A later hydration look
    /// must not put the popup back over the page.
    func testADismissedPlayerStaysClosedAfterHydration() {
        offer(Self.noVideoSignal, at: Self.mediaPages[0])
        tapPill()
        XCTAssertTrue(overlayExists(), "the resolved video should open from the pill")
        dismissOverlay()
        XCTAssertFalse(overlayExists())
        _ = js.evaluate("document.body.appendChild(document.createElement(\"video\")); \"hydrated\"")
        XCTAssertFalse(
            waitForOverlay(within: 1), "a dismissed player reopened itself")
    }

    /// …but the pill is still the way back to it.
    func testThePillReopensThePlayerAfterADismissal() {
        offer(at: Self.mediaPages[0])
        tapPill()
        XCTAssertTrue(waitForOverlay())
        dismissOverlay()
        tapPill()
        XCTAssertTrue(overlayExists(), "the pill should reopen the player it opened once")
    }

    // MARK: - The page's own player

    /// The requested panel can open BEFORE the page's own video necessarily exists, so the
    /// pause cannot be a one-shot sweep: a post that hydrates and autoplays a
    /// second later would otherwise play, unmuted, behind the panel.
    func testAPageVideoThatStartsAfterThePlayerOpensIsPaused() {
        offer(at: Self.mediaPages[0])
        tapPill()
        XCTAssertTrue(waitForOverlay())
        _ = js.evaluate("""
            var late = document.createElement("video");
            late.id = "late-page-video";
            document.body.appendChild(late);
            // No source to decode in the harness; record the pause the guard asks
            // for and announce the play the way a real element would.
            late.__paused = false;
            Object.defineProperty(late, "paused", { get: function () { return this.__paused; } });
            late.pause = function () { this.__paused = true; };
            late.dispatchEvent(new Event("play"));
            "played"
            """)
        XCTAssertTrue(
            js.bool("document.getElementById(\"late-page-video\").paused"),
            "a page video that starts behind the panel must be paused")
    }

    // MARK: - Reddit

    /// Reddit's video and audio are separate DASH streams, so there is nothing a
    /// single `<video>` can play: its pill keeps the plain hand-off, and it never
    /// enters the overlay path.
    func testARedditPostNeverOpensThePlayerAndStillHandsOff() {
        js.load(
            html: """
                <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
                </head><body style="margin:0">
                <shreddit-post post-type="video"></shreddit-post></body></html>
                """,
            urlString: "https://www.reddit.com/r/videos/comments/1abc2d/title/",
            scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        _ = js.evaluate("""
            window.__lunaOfferLunaButton({ scheme: "lunadownloader", supportsMedia: true });
            "offered"
            """)
        XCTAssertTrue(pillExists(), "a video reddit post should still get its pill")
        XCTAssertFalse(waitForOverlay(within: 0.5), "reddit must not enter the overlay path")
        let opened = js.awaitAppSchemeNavigation { self.tapPill() } ?? ""
        XCTAssertTrue(opened.hasPrefix("lunadownloader://read?url="), "got \(opened)")
    }

    func testRedditTextAndPhotoPostsNeverOpenWithPluginsEnabled() {
        for postType in ["text", "image"] {
            js.load(
                html: "<html><body><shreddit-post post-type=\"\(postType)\"></shreddit-post></body></html>",
                urlString: "https://www.reddit.com/r/pics/comments/1abc2d/title/",
                scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
            _ = js.evaluate("""
                window.__lunaStartPillDecision(
                    { scheme: "luna", supportsMedia: true, supportsPlugins: true });
                "offered"
                """)
            XCTAssertFalse(pillExists(), postType)
            XCTAssertFalse(overlayExists(), postType)
        }
    }

    // MARK: - Turned off

    /// Loads a media page and runs the pill decision with the player switched OFF
    /// in the host app's Settings — the shape of the `buttonContext` reply the
    /// native handler sends when `safariVideoPlayerEnabled` is false.
    private func offerWithPlayerDisabled(at urlString: String) {
        js.load(
            html: Self.videoPost, urlString: urlString,
            scripts: [SafariJSTestHarness.platformHosts, SafariJSTestHarness.contentScript])
        _ = js.evaluate("""
            window.__lunaOfferLunaButton(
                { scheme: "lunadownloader", supportsMedia: true, videoPlayer: false });
            "offered"
            """)
    }

    /// Disabling Play in Safari keeps the player closed.
    func testTheDisabledPlayerNeverOpensItself() {
        offerWithPlayerDisabled(at: Self.mediaPages[0])
        XCTAssertFalse(
            waitForOverlay(within: 0.5), "the player opened on a page with it switched off")
    }

    /// And the pill goes back to being what it was before the player existed:
    /// still offered, still the media hand-off, still bouncing back to Safari.
    func testTheDisabledPlayersPillHandsTheLinkToTheApp() {
        offerWithPlayerDisabled(at: Self.mediaPages[0])
        XCTAssertTrue(pillExists(), "turning the player off must not cost the page its pill")
        let opened = js.awaitAppSchemeNavigation { self.tapPill() } ?? ""
        XCTAssertTrue(opened.hasPrefix("lunadownloader://read?url="), "got \(opened)")
        XCTAssertTrue(opened.hasSuffix("&ret=safari"), "got \(opened)")
        XCTAssertFalse(overlayExists(), "a tap must not open the player either")
    }
}
