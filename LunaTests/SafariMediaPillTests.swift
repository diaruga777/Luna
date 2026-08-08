//
//  SafariMediaPillTests.swift
//  LunaTests
//

import XCTest

/// The route from a media page to the in-page player: which target a recognized
/// platform page earns, when the player opens ITSELF, and what tapping the pill
/// does once it has.
///
/// `SafariVideoOverlayTests` drives `__lunaPresentVideoOverlay` directly with a
/// hand-built hand-off, so it proves what the overlay does once open and nothing
/// about how the user gets there. This suite runs the real decision
/// (`offerLunaButton` -> `videoOverlayTargetFor` -> `injectLunaButton` +
/// `autoPresentVideoOverlay`) against each platform host that reaches it.
@MainActor
final class SafariMediaPillTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    /// A post page whose subject is a video — the signal the auto-open waits for.
    private static let videoPost = """
        <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
        <meta property="og:video" content="https://cdn.example.com/v.mp4">
        </head><body style="margin:0"><p>fixture</p></body></html>
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
            window.__lunaSetResolveMediaRequest(function () {
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

    /// Polls for `predicate` — the auto-open's later looks and the resolve both
    /// land on a timer/microtask, so there is nothing to await directly.
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
        _ = js.evaluate("document.getElementById(window.__lunaPillID).click(); \"tapped\"")
        // The resolve settles on a microtask; a second round trip is past it.
        _ = js.evaluate("void 0")
    }

    // MARK: - The player opens itself

    /// The whole point: on a post page whose subject is a video, nothing has to
    /// be tapped.
    func testThePlayerOpensWithoutATapOnEveryMediaPage() {
        for page in Self.mediaPages {
            offer(at: page)
            XCTAssertTrue(waitForOverlay(), "no player opened on \(page)")
            XCTAssertTrue(
                eventually("""
                    (function () {
                        var overlay = document.getElementById(window.__lunaVideoOverlayID);
                        var video = overlay && overlay.querySelector("video");
                        return !!video
                            && video.getAttribute("src") === "https://cdn.example.com/v.mp4";
                    })()
                    """),
                "the resolved video didn't reach the stage on \(page)")
        }
    }

    /// The pill stays: it is the way back after a dismissal, and the hand-off on
    /// a page that never resolves.
    func testThePillIsStillOfferedBehindThePlayer() {
        offer(at: Self.mediaPages[0])
        XCTAssertTrue(waitForOverlay())
        XCTAssertTrue(pillExists())
    }

    /// A client-rendered post often has neither `<video>` nor video metadata at
    /// `document_idle`; the bounded retry walk is what keeps the auto-open from
    /// depending on hydration having finished first.
    func testAVideoThatHydratesAfterThePillStillOpensThePlayer() {
        offer(Self.noVideoSignal, at: Self.mediaPages[1])
        XCTAssertFalse(overlayExists(), "nothing to play yet — nothing should open")
        _ = js.evaluate("document.body.appendChild(document.createElement(\"video\")); \"hydrated\"")
        XCTAssertTrue(
            waitForOverlay(within: secondLook + 1),
            "a <video> that appears after the pill should still open the player")
    }

    /// The walk's second look, in seconds — read from the script rather than
    /// restated here, so a change to the schedule can't silently slow this suite
    /// into flakiness.
    private var secondLook: TimeInterval {
        js.number("window.__lunaAutoPlayerRetryDelays[1]") / 1000
    }

    /// A bare platform host or a feed shell earns a pill, but a panel over
    /// someone's feed is a different thing from a button offered beside it.
    func testAPageWithNoVideoSignalOffersThePillWithoutOpeningThePlayer() {
        offer(Self.noVideoSignal, at: "https://x.com/home")
        XCTAssertTrue(pillExists(), "the pill's own gate is unchanged")
        XCTAssertFalse(waitForOverlay(within: 0.5), "no video on the page, no panel over it")
    }

    // MARK: - Dismissal

    /// Closing it is the user saying "not this page", and a look still pending
    /// from the hydration walk must respect that rather than putting the panel
    /// back seconds later. (Opened from the pill here, so the walk is still
    /// waiting for a signal when the dismissal lands — the one arrangement where
    /// the two can actually race.)
    func testADismissalStopsThePendingAutoOpen() {
        offer(Self.noVideoSignal, at: Self.mediaPages[0])
        tapPill()
        XCTAssertTrue(overlayExists(), "the pill should open it even with nothing found yet")
        dismissOverlay()
        XCTAssertFalse(overlayExists())
        _ = js.evaluate("document.body.appendChild(document.createElement(\"video\")); \"hydrated\"")
        XCTAssertFalse(
            waitForOverlay(within: secondLook + 1), "a dismissed player reopened itself")
    }

    /// …but the pill is still the way back to it.
    func testThePillReopensThePlayerAfterADismissal() {
        offer(at: Self.mediaPages[0])
        XCTAssertTrue(waitForOverlay())
        dismissOverlay()
        tapPill()
        XCTAssertTrue(overlayExists(), "the pill should reopen the player it opened once")
    }

    // MARK: - The page's own player

    /// The panel now opens BEFORE the page's own video necessarily exists, so the
    /// pause cannot be a one-shot sweep: a post that hydrates and autoplays a
    /// second later would otherwise play, unmuted, behind the panel.
    func testAPageVideoThatStartsAfterThePlayerOpensIsPaused() {
        offer(at: Self.mediaPages[0])
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
    /// enters the overlay path — auto-open included.
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
}
