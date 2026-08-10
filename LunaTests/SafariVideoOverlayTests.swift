//
//  SafariVideoOverlayTests.swift
//  LunaTests
//

@testable import Luna
import LunaMediaResolve
import LunaModels
import LunaURLClassification
import XCTest

/// The in-page video player: the overlay `content.js` opens when the download
/// pill is tapped on a media page in a media-handling host.
///
/// Driven through the production `content.js` in the shared bare `WKWebView` —
/// which has no extension host, so the native round trip is substituted via the
/// `window.__lunaSetResolveMediaRequest` seam the script exports for exactly this.
@MainActor
final class SafariVideoOverlayTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private static let pageURL = "https://www.instagram.com/reel/ABC123/"
    private static let assetURL = "https://scontent.cdninstagram.com/v/reel.mp4"
    private static let posterURL = "https://scontent.cdninstagram.com/v/cover.jpg"

    override func setUp() {
        super.setUp()
        // A fresh document per test (one overlay must not leak into the next) on
        // the ONE shared web view.
        loadFixture()
    }

    /// The fixture page, with the panel's growth animation turned off through the
    /// seam `content.js` exposes for it. Every shape assertion below is about the
    /// height the panel SETTLES at, and reading a `getBoundingClientRect` while a
    /// 0.24s transition is still in flight measures the height it is leaving.
    private func loadFixture(html: String = SafariJSSource.blankPage) {
        js.load(html: html, urlString: Self.pageURL)
        _ = js.evaluate("window.__lunaSetPlayerGrowthSeconds(0); \"instant\"")
    }

    // MARK: - Driving the overlay

    /// Stubs the native resolve with `assets`, then opens the player. `assets` is
    /// JS source for the array the handler would have answered with.
    private func present(assets: String, scheme: String = "lunadownloader") {
        _ = js.evaluate("""
            window.__lunaSetResolveMediaRequest(function () {
                return Promise.resolve({ assets: \(assets) });
            });
            window.__lunaPresentVideoOverlay(
                { scheme: \(json(scheme)), supportsMedia: true },
                { label: "Download in Luna",
                  url: function () {
                      return \(json(scheme)) + "://read?url="
                          + encodeURIComponent(location.href) + "&ret=safari";
                  } });
            "presented"
            """)
        // The resolve settles on a microtask; a second round trip through
        // `evaluateJavaScript` is already past it.
        _ = js.evaluate("void 0")
    }

    private var playableAsset: String {
        "[{ url: \(json(Self.assetURL)), kind: \"video\", thumbnailURL: \(json(Self.posterURL)) }]"
    }

    private func overlayExists() -> Bool {
        js.bool("!!document.getElementById(window.__lunaVideoOverlayID)")
    }

    private func videoSource() -> String? {
        js.string("""
            (function () {
                var overlay = document.getElementById(window.__lunaVideoOverlayID);
                var video = overlay && overlay.querySelector("video");
                return video ? (video.getAttribute("src") || "") : null;
            })()
            """)
    }

    private func stageText() -> String {
        js.string("""
            (function () {
                var overlay = document.getElementById(window.__lunaVideoOverlayID);
                return overlay ? overlay.textContent : "";
            })()
            """) ?? ""
    }

    private func json(_ value: String) -> String { SafariJSTestHarness.jsString(value) }

    // MARK: - Resolved

    func testAResolvedVideoIsPlayedInThePage() {
        present(assets: playableAsset)
        XCTAssertTrue(overlayExists())
        XCTAssertEqual(videoSource(), Self.assetURL)
    }

    /// Inline playback and native controls, not a full-screen takeover the
    /// moment the user hits play.
    func testThePlayerIsInlineAndCarriesNativeControls() {
        present(assets: playableAsset)
        XCTAssertTrue(js.bool("""
            (function () {
                var v = document.getElementById(window.__lunaVideoOverlayID).querySelector("video");
                return v.hasAttribute("controls") && v.hasAttribute("playsinline");
            })()
            """))
    }

    /// The poster fills the stage while the stream is still opening.
    func testThePosterIsUsedWhenTheResolveSuppliesOne() {
        present(assets: playableAsset)
        XCTAssertEqual(
            js.string("""
                document.getElementById(window.__lunaVideoOverlayID)
                    .querySelector("video").getAttribute("poster")
                """),
            Self.posterURL)
    }

    func testAResolveWithoutAThumbnailStillPlays() {
        present(assets: "[{ url: \(json(Self.assetURL)), kind: \"video\" }]")
        XCTAssertEqual(videoSource(), Self.assetURL)
        XCTAssertFalse(js.bool("""
            document.getElementById(window.__lunaVideoOverlayID)
                .querySelector("video").hasAttribute("poster")
            """))
    }

    // MARK: - Degrading

    /// An empty answer — an unsupported host, a resolve failure, a split
    /// audio/video post the handler refused, or its own timeout — leaves the
    /// panel up with a message and no player. The Download button below it is
    /// what the user came for and stays.
    func testAnEmptyResolveDegradesToTheHandoff() {
        present(assets: "[]")
        XCTAssertTrue(overlayExists())
        XCTAssertNil(videoSource())
        XCTAssertTrue(
            stageText().contains(
                js.string("window.__lunaMessageDefaults.videoUnplayable") ?? "!"),
            "the degraded stage should say the video can't play here, got: \(stageText())")
    }

    /// A resolve that answers something with no URL is the same failure.
    func testAnAssetWithNoURLDegrades() {
        present(assets: "[{ kind: \"video\" }]")
        XCTAssertNil(videoSource())
    }

    /// A rejected round trip must not leave the player spinning forever.
    func testARejectedResolveDegrades() {
        _ = js.evaluate("""
            window.__lunaSetResolveMediaRequest(function () {
                return Promise.reject(new Error("no native host"));
            });
            window.__lunaPresentVideoOverlay(
                { scheme: "lunadownloader", supportsMedia: true },
                { label: "Download in Luna", url: function () { return "lunadownloader://read"; } });
            "presented"
            """)
        _ = js.evaluate("void 0")
        XCTAssertTrue(overlayExists())
        XCTAssertNil(videoSource())
    }

    /// The media element itself is the last line: the page's CSP has the final
    /// say on the load, and an expired CDN URL 403s. Either surfaces as `error`.
    func testAVideoErrorDegradesTheStage() {
        present(assets: playableAsset)
        XCTAssertNotNil(videoSource())
        _ = js.evaluate("""
            var v = document.getElementById(window.__lunaVideoOverlayID).querySelector("video");
            v.dispatchEvent(new Event("error"));
            "dispatched"
            """)
        XCTAssertNil(videoSource())
        XCTAssertTrue(overlayExists(), "the panel stays — Download is still offered")
    }

    // MARK: - Dismissal

    func testTheCloseButtonRemovesEverything() {
        present(assets: playableAsset)
        _ = js.evaluate("""
            document.getElementById(window.__lunaVideoOverlayID)
                .querySelector('[role="button"][aria-label]').click();
            "closed"
            """)
        XCTAssertFalse(overlayExists())
        XCTAssertEqual(js.number("document.querySelectorAll(\"video\").length"), 0)
    }

    func testTappingTheBackdropCloses() {
        present(assets: playableAsset)
        _ = js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); \"closed\"")
        XCTAssertFalse(overlayExists())
    }

    /// A tap on the panel is a tap on the player, never a dismissal.
    func testTappingInsideThePanelDoesNotClose() {
        present(assets: playableAsset)
        _ = js.evaluate("""
            document.getElementById(window.__lunaVideoOverlayID).firstChild.click();
            "tapped"
            """)
        XCTAssertTrue(overlayExists())
    }

    func testPresentingTwiceLeavesOneOverlay() {
        present(assets: playableAsset)
        present(assets: playableAsset)
        XCTAssertEqual(
            js.number("document.querySelectorAll('[id=\"luna-video-overlay\"]').length"), 1)
    }

    // MARK: - Download

    /// Resolved: the handler already holds the assets, so the app gets the
    /// payload-free drain link — never the page URL again.
    private func downloadNavigation() -> String? {
        js.awaitAppSchemeNavigation {
            _ = self.js.evaluate("""
                (function () {
                    var buttons = document.getElementById(window.__lunaVideoOverlayID)
                        .querySelectorAll('[role="button"]');
                    buttons[buttons.length - 1].click();
                    return "tapped";
                })()
                """)
        }
    }

    func testDownloadAfterAResolveOpensTheDrainLink() {
        present(assets: playableAsset)
        XCTAssertEqual(downloadNavigation(), "lunadownloader://resolvedmedia?ret=safari")
    }

    /// Degraded: the app is handed the PAGE, exactly as this pill did before the
    /// player existed, so nothing is lost when inline playback isn't possible.
    func testDownloadAfterADegradedResolveOpensTheOriginalHandoff() {
        present(assets: "[]")
        let opened = downloadNavigation() ?? ""
        XCTAssertTrue(opened.hasPrefix("lunadownloader://read?url="), "got \(opened)")
        XCTAssertTrue(opened.hasSuffix("&ret=safari"), "got \(opened)")
    }

    // MARK: - The page's own player

    /// Every platform this pill appears on autoplays its own video, and an
    /// overlay does not stop it — two videos playing at once, two soundtracks.
    func testThePagesOwnVideoIsPausedWhileTheOverlayIsUp() {
        _ = js.evaluate("""
            var page = document.createElement("video");
            page.id = "page-video";
            document.body.appendChild(page);
            // No source to decode in the harness; fake the playing state the
            // overlay reads, and record the pause it asks for.
            Object.defineProperty(page, "paused", { get: function () { return this.__paused; } });
            page.__paused = false;
            page.pause = function () { this.__paused = true; };
            page.play = function () { this.__paused = false; return Promise.resolve(); };
            "seeded"
            """)
        present(assets: playableAsset)
        XCTAssertTrue(js.bool("document.getElementById(\"page-video\").__paused"))
    }

    /// And it resumes when the overlay goes away.
    func testThePagesOwnVideoResumesOnDismiss() {
        _ = js.evaluate("""
            var page = document.createElement("video");
            page.id = "page-video";
            document.body.appendChild(page);
            Object.defineProperty(page, "paused", { get: function () { return this.__paused; } });
            page.__paused = false;
            page.pause = function () { this.__paused = true; };
            page.play = function () { this.__paused = false; return Promise.resolve(); };
            "seeded"
            """)
        present(assets: playableAsset)
        _ = js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); \"closed\"")
        XCTAssertFalse(js.bool("document.getElementById(\"page-video\").__paused"))
    }

    /// A video the user had ALREADY paused must not be started for them.
    func testAnAlreadyPausedPageVideoIsNotResumed() {
        _ = js.evaluate("""
            var page = document.createElement("video");
            page.id = "page-video";
            document.body.appendChild(page);
            Object.defineProperty(page, "paused", { get: function () { return this.__paused; } });
            page.__paused = true;
            page.pause = function () { this.__paused = true; };
            page.play = function () { this.__paused = false; return Promise.resolve(); };
            "seeded"
            """)
        present(assets: playableAsset)
        _ = js.evaluate("document.getElementById(window.__lunaVideoOverlayID).click(); \"closed\"")
        XCTAssertTrue(js.bool("document.getElementById(\"page-video\").__paused"))
    }

    // MARK: - Shape

    /// Near the full width, capped so it doesn't stretch across an iPad, and only
    /// as tall as its contents.
    func testThePanelIsNearlyFullWidthAndHugsItsContents() {
        present(assets: playableAsset)
        let panelWidth = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .firstChild.getBoundingClientRect().width
            """)
        let panelHeight = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .firstChild.getBoundingClientRect().height
            """)
        let viewportWidth = js.number("window.innerWidth")
        let viewportHeight = js.number("window.innerHeight")

        XCTAssertGreaterThan(
            panelWidth, viewportWidth * 0.85,
            "the panel should be near the full width of the screen")
        XCTAssertLessThanOrEqual(panelWidth, viewportWidth)
        XCTAssertLessThan(
            panelHeight, viewportHeight * 0.75,
            "the panel must hug its contents, not fill the screen")
    }

    // MARK: - The popup's height follows the clip

    private func rect(_ selector: String) -> (width: Double, height: Double) {
        let width = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .\(selector).getBoundingClientRect().width
            """)
        let height = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .\(selector).getBoundingClientRect().height
            """)
        return (width, height)
    }

    private func panelRect() -> (width: Double, height: Double) { rect("firstChild") }

    /// The clip's real shape, as the element reports it once the stream opens.
    private func reportMetadata(width: Int, height: Int) {
        _ = js.evaluate("""
            (function () {
                var video = document.getElementById(window.__lunaVideoOverlayID)
                    .querySelector("video");
                Object.defineProperty(video, "videoWidth", { get: function () { return \(width); } });
                Object.defineProperty(video, "videoHeight", { get: function () { return \(height); } });
                video.dispatchEvent(new Event("loadedmetadata"));
                return "reported";
            })()
            """)
    }

    /// The panel opens at 16:9 and a 16:9 clip leaves it exactly there — this
    /// feature costs the shape that shipped nothing.
    func testAWideClipKeepsThePanelItAlwaysHad() {
        present(assets: playableAsset)
        let before = panelRect().height
        reportMetadata(width: 1920, height: 1080)
        XCTAssertEqual(panelRect().height, before, accuracy: 1)
    }

    /// And neither does a clip WIDER than 16:9: the opening shape is a floor, not
    /// a starting point, so a panel can only ever grow from it.
    func testAnUltraWideClipDoesNotShrinkThePanel() {
        present(assets: playableAsset)
        let before = panelRect().height
        reportMetadata(width: 2560, height: 400)
        XCTAssertEqual(panelRect().height, before, accuracy: 1)
    }

    /// A 9:16 reel in a 16:9 letterbox is mostly black bars. Reported tall, the
    /// stage takes the clip's own shape and the popup grows under it.
    func testATallClipGrowsThePopup() {
        present(assets: playableAsset)
        let before = panelRect().height
        reportMetadata(width: 1080, height: 1920)
        let after = panelRect().height
        XCTAssertGreaterThan(
            after, before + 100,
            "a 9:16 clip did not grow the popup at all — it is still letterboxed")
    }

    /// …but only as far as what is ON SCREEN. `100vh` and the backdrop's own
    /// `position: fixed` box are both the LARGE viewport (toolbars retracted), so
    /// a panel measured against either runs under Safari's chrome; the clamp is
    /// taken from `visualViewport`, and leaves an inset top and bottom.
    func testTheGrownPopupStaysInsideTheVisibleViewport() {
        present(assets: playableAsset)
        reportMetadata(width: 1080, height: 1920)

        let visible = js.number("""
            window.visualViewport ? window.visualViewport.height : window.innerHeight
            """)
        let panel = panelRect().height
        XCTAssertLessThanOrEqual(
            panel, visible - 20,
            "the grown popup fills the visible viewport edge to edge — it owes an inset")
        XCTAssertGreaterThan(
            panel, visible * 0.7,
            "a tall clip should take nearly the whole visible viewport, not a little more "
                + "than 16:9")
    }

    /// The panel is centred in what the user can see rather than in the layout
    /// viewport, so neither end of it is behind Safari's chrome.
    func testTheGrownPopupIsCentredInWhatIsVisible() {
        present(assets: playableAsset)
        reportMetadata(width: 1080, height: 1920)

        let top = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .firstChild.getBoundingClientRect().top
            """)
        let bottom = js.number("""
            document.getElementById(window.__lunaVideoOverlayID)
                .firstChild.getBoundingClientRect().bottom
            """)
        let box = js.number("""
            window.__lunaVisiblePageBox().top + window.__lunaVisiblePageBox().height
            """)
        XCTAssertGreaterThan(top, 0, "the popup's top edge is off the top of the visible box")
        XCTAssertLessThanOrEqual(
            bottom, box, "the popup's bottom edge is under Safari's toolbar")
    }

    /// The page can sometimes say the shape before the stream opens (Open Graph
    /// video dimensions), which is a beat earlier than `loadedmetadata`.
    func testThePagesOwnVideoDimensionsSizeTheStageImmediately() {
        loadFixture(html: """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta property="og:video:width" content="720">
            <meta property="og:video:height" content="1280">
            </head><body style="margin:0"><p>fixture</p></body></html>
            """)
        present(assets: playableAsset)
        let visible = js.number("""
            window.visualViewport ? window.visualViewport.height : window.innerHeight
            """)
        XCTAssertGreaterThan(
            panelRect().height, visible * 0.7,
            "the panel ignored the page's own declared video dimensions")
    }

    /// Whatever the page claimed, the element is the authority: a page whose
    /// metadata lies about the clip must not leave the popup the wrong shape.
    func testTheElementsMetadataOverridesThePages() {
        loadFixture(html: """
            <html><head><meta name="viewport" content="width=device-width, initial-scale=1">
            <meta property="og:video:width" content="720">
            <meta property="og:video:height" content="1280">
            </head><body style="margin:0"><p>fixture</p></body></html>
            """)
        present(assets: playableAsset)
        let claimed = panelRect().height
        reportMetadata(width: 1920, height: 1080)
        XCTAssertLessThan(
            panelRect().height, claimed - 100,
            "the panel kept the page's claimed shape after the clip reported a wide one")
    }

    /// The resolve usually knows the rendition's size (the CDN names it in the
    /// URL), and it lands a whole round trip before the element's metadata — so
    /// the panel opens at the clip's shape rather than growing into it.
    func testTheResolvedSizeShapesTheStageBeforeAnythingStreams() {
        present(assets: """
            [{ url: \(json(Self.assetURL)), kind: "video", width: 720, height: 1280 }]
            """)
        let visible = js.number("""
            window.visualViewport ? window.visualViewport.height : window.innerHeight
            """)
        XCTAssertGreaterThan(
            panelRect().height, visible * 0.7,
            "the panel ignored the size the resolve already knew")
    }

    /// The stage's inline `transition`, which is set only for a size change the
    /// user is watching happen (empty while the panel is still arriving).
    private func stageTransition() -> String {
        js.string("""
            document.getElementById(window.__lunaVideoOverlayID)
                .firstChild.children[1].style.transition
            """) ?? ""
    }

    /// Arriving at a size is not the same act as changing size. A shape known
    /// while the panel is still appearing is applied outright…
    func testAShapeKnownAsThePanelOpensIsNotAnimated() {
        present(assets: playableAsset)
        reportMetadata(width: 1080, height: 1920)
        XCTAssertEqual(stageTransition(), "", "the panel animated its way to its opening size")
    }

    /// …but a platform that declares nothing anywhere can leave the answer to
    /// the stream, and on iOS the stream can withhold it until the Play tap. A
    /// first shape that turns up then must settle, not snap under the thumb.
    func testAShapeThatOnlyArrivesAtPlayTimeSettlesInsteadOfSnapping() {
        present(assets: playableAsset)
        let window = js.number("window.__lunaInstantSizingMilliseconds") / 1000
        RunLoop.current.run(until: Date().addingTimeInterval(window + 0.2))
        reportMetadata(width: 1080, height: 1920)
        XCTAssertTrue(
            stageTransition().contains("height"),
            "a late first shape resized the panel with no animation at all")
    }

    /// Mobile Safari may withhold its first metadata callback until playback.
    /// The player explicitly asks for metadata and keeps listening to later
    /// readiness signals, so the first Play tap is not the first time it sizes.
    func testThePlayerProactivelyLoadsAndKeepsReadingItsAspect() {
        let builder = SafariJSTestHarness.source("LunaSafari/Resources/content.js")
            .components(separatedBy: "function presentVideoOverlay(").last ?? ""
        XCTAssertTrue(builder.contains("video.load()"))
        for event in ["loadedmetadata", "loadeddata", "canplay", "durationchange", "playing"] {
            XCTAssertTrue(builder.contains("\"\(event)\""), "missing aspect retry on \(event)")
        }
    }

    // MARK: - Which pages get it

}

/// The contract the player depends on across its three processes — the page, the
/// appex, and the app — and the architectural rule that keeps them from drifting.
final class SafariVideoOverlayContractTests: XCTestCase {

    private static func source(_ relativePath: String) -> String {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        return (try? String(
            contentsOf: repoRoot.appendingPathComponent(relativePath), encoding: .utf8)) ?? ""
    }

    private var contentScript: String { Self.source("LunaSafari/Resources/content.js") }
    private var background: String { Self.source("LunaSafari/Resources/background.js") }
    private var handler: String { Self.source("LunaSafari/SafariWebExtensionHandler.swift") }

    // MARK: - The message protocol

    /// A content script can't reach the native handler except through
    /// background.js, so a message named on one side and not the other is a
    /// silently dead feature.
    func testBothNewMessagesAreRelayedEndToEnd() {
        for message in ["resolveMedia", "queueResolvedDownload"] {
            XCTAssertTrue(contentScript.contains(message), "content.js never sends \(message)")
            XCTAssertTrue(background.contains(message), "background.js drops \(message)")
            XCTAssertTrue(handler.contains("\"\(message)\""), "the handler answers no \(message)")
        }
    }

    /// Every background relay degrades rather than rejecting — a native side that
    /// isn't there must read as "nothing resolved", not as an unhandled rejection.
    func testTheRelayDegradesToAnEmptyAnswer() {
        XCTAssertTrue(
            background.contains("return { assets: [] }; }"),
            "the resolveMedia relay must catch into an empty asset list")
        XCTAssertTrue(
            background.contains("return { queued: false }; }"),
            "the queueResolvedDownload relay must catch into a refusal")
    }

    func testReturningFromTheAppReusesTheFreshPageResolve() {
        XCTAssertTrue(handler.contains("ResolvedMediaCache.shared.record(forURLString:"))
        XCTAssertTrue(handler.contains("playbackResolveReuseLifetime"))
    }

    // MARK: - Which viewport the panel is measured against

    /// The one thing about the adaptive height that no rendering test can pin,
    /// because a bare `WKWebView` has no browser chrome to be wrong about: the
    /// clamp must come from `visualViewport`. `100vh` is the LARGE viewport (as
    /// though the toolbars were retracted) and `position: fixed` is laid out
    /// against that same box, so a popup sized by either runs under Safari's
    /// address bar on a real device while every simulator test still passes.
    func testTheHeightIsClampedToTheVisualViewport() {
        XCTAssertTrue(
            contentScript.contains("window.visualViewport"),
            "the player no longer asks visualViewport how much of the page is on screen")
        let builder = contentScript
            .components(separatedBy: "function presentVideoOverlay(").last ?? ""
        let panelSection = builder
            .components(separatedBy: "\n    function autoPresentVideoOverlay(").first ?? ""
        XCTAssertFalse(
            panelSection.contains("100vh") || panelSection.contains("100dvh"),
            "the panel is sized in viewport units again — those are the layout viewport, "
                + "which includes the space Safari's toolbars sit in")
        XCTAssertTrue(
            panelSection.contains("env(safe-area-inset-top)")
                && panelSection.contains("env(safe-area-inset-bottom)"),
            "the panel must keep clear of the notch and the home indicator, which "
                + "visualViewport reports as part of the visible box")
    }

    // MARK: - The deep link

    /// `content.js` builds the drain link as a string; `LunaDeepLink` parses it.
    func testTheDrainLinkContentJSBuildsIsTheOneTheAppRoutes() throws {
        XCTAssertTrue(
            contentScript.contains("://\(LunaDeepLink.resolvedMediaHost)?ret=safari"),
            "content.js no longer builds \(LunaDeepLink.resolvedMediaHost) — the app would "
                + "route a host nothing navigates to")

        let built = try XCTUnwrap(URL(string: "lunadownloader://\(LunaDeepLink.resolvedMediaHost)?ret=safari"))
        XCTAssertTrue(LunaDeepLink.isResolvedMediaLink(built))
        XCTAssertTrue(LunaDeepLink.requestsReturnToSource(built))
    }

    /// A payload-free drain link, like `rescue`: nothing about the media rides
    /// the URL, so it can't truncate and the foreground drain is equivalent.
    func testTheDrainLinkCarriesNoPayload() throws {
        let link = try XCTUnwrap(URL(string: "lunadownloader://\(LunaDeepLink.resolvedMediaHost)"))
        XCTAssertEqual(link.absoluteString, "lunadownloader://resolvedmedia")
        XCTAssertNil(URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems)
    }

    // MARK: - Where the work runs

    /// THE invariant of this feature: extraction is shared Swift, in one place.
    ///
    /// The Safari handler is an ADAPTER — parse the message, call
    /// `SocialMediaResolver`, serialize the answer. If a platform's extraction
    /// ever gets copied in here "just for Safari", the app and the extension
    /// start disagreeing about what a link resolves to, which is the exact
    /// failure the `LunaSafari/Shared*.swift` hand-copies were tolerable for
    /// (tiny, stable key formats) and this would not be.
    func testTheNativeHandlerCallsTheSharedResolverAndParsesNothingItself() {
        XCTAssertTrue(
            handler.contains("SocialMediaResolver()"),
            "the handler must resolve through the shared LunaMediaResolve resolver")
        for forbidden in ["URLSession", "JSONSerialization", "components(separatedBy:", "fxtwitter"] {
            XCTAssertFalse(
                handler.contains(forbidden),
                "SafariWebExtensionHandler mentions \(forbidden) — fetching or parsing in the "
                    + "extension is a fork of LunaMediaResolve waiting to happen")
        }
    }

    /// The player's off switch crosses all three processes as a bare App Group
    /// key: Settings writes it, the appex reads it as a literal (it links no app
    /// code), the page acts on the answer. A key that agrees on two sides out of
    /// three is a setting that silently does nothing.
    func testTheOffSwitchIsOneAppGroupKeyAcrossAllThreeProcesses() {
        XCTAssertTrue(
            handler.contains("\"\(SafariSuggestionSettings.videoPlayerKey)\""),
            "the Safari handler reads a different key than Settings writes")
        XCTAssertTrue(
            contentScript.contains("context.videoPlayer === false"),
            "content.js no longer honours the handler's videoPlayer answer")
        XCTAssertTrue(
            handler.contains("payload[\"videoPlayer\"]"),
            "the handler stopped sending the answer content.js waits for")
    }

    /// And no OTHER file in the extension may grow one either.
    func testNoExtensionSourceReimplementsResolution() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
        let directory = repoRoot.appendingPathComponent("LunaSafari")
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".swift") }
        XCTAssertFalse(names.isEmpty, "no LunaSafari sources found")

        for name in names where name != "SafariWebExtensionHandler.swift" {
            let source = try String(
                contentsOf: directory.appendingPathComponent(name), encoding: .utf8)
            for marker in ["MediaAsset", "playAddr", "video_url", "googlevideo"] {
                XCTAssertFalse(
                    source.contains(marker),
                    "\(name) mentions \(marker) — media resolution belongs in LunaMediaResolve, "
                        + "which every surface links, not in a Safari-local copy")
            }
        }
    }

    /// The page is told what to PLAY, never what was resolved: an asset's audio
    /// stream, DASH manifest and byte estimate stay in Swift, so JS has no
    /// `MediaAsset` shape to mirror and drift from.
    func testThePageNeverReceivesTheWholeAsset() {
        for field in ["audioURL", "dashManifestURL", "estimatedByteCount", "timeRange"] {
            XCTAssertFalse(
                contentScript.contains(field),
                "content.js reads \(field) — the page should only ever receive a URL, a kind "
                    + "and a thumbnail")
        }
    }

    // MARK: - Playability is a Swift rule

    /// Which assets an in-page `<video>` can take is decided in LunaMediaResolve,
    /// not by a platform list in the extension — which is why Reddit falls out
    /// without anything naming Reddit.
    func testSplitStreamAssetsAreNotDirectlyPlayable() {
        let reddit = MediaAsset(
            url: URL(string: "https://v.redd.it/a/DASH_720.mp4")!, kind: .video,
            audioURL: URL(string: "https://v.redd.it/a/DASH_audio.mp4"),
            dashManifestURL: URL(string: "https://v.redd.it/a/DASHPlaylist.mpd"))
        XCTAssertFalse(reddit.isDirectlyPlayable)

        let single = MediaAsset(url: URL(string: "https://video.twimg.com/a.mp4")!, kind: .video)
        XCTAssertTrue(single.isDirectlyPlayable)

        let animated = MediaAsset(url: URL(string: "https://video.twimg.com/a.mp4")!, kind: .gif)
        XCTAssertTrue(animated.isDirectlyPlayable)

        let still = MediaAsset(url: URL(string: "https://pbs.twimg.com/a.jpg")!, kind: .image)
        XCTAssertFalse(still.isDirectlyPlayable)
    }

    // MARK: - The shape is a Swift rule too

    /// Where a platform names the rendition in its URL, the resolve already
    /// knows the clip's shape — read in LunaMediaResolve, like playability, so
    /// the extension keeps parsing nothing.
    func testADeclaredRenditionSizeIsReadFromTheAssetURL() {
        let x = MediaAsset(
            url: URL(string: "https://video.twimg.com/ext_tw_video/1/pu/vid/avc1/720x1280/a.mp4")!,
            kind: .video)
        XCTAssertEqual(x.declaredPixelSize, MediaPixelSize(width: 720, height: 1280))
        XCTAssertEqual(x.declaredPixelSize?.aspectHeightOverWidth ?? 0, 1280.0 / 720.0, accuracy: 0.001)

        // The most specific segment wins where a path names more than one.
        let nested = MediaAsset(
            url: URL(string: "https://cdn.example.com/2x2/renditions/1920x1080/clip.mp4")!,
            kind: .video)
        XCTAssertEqual(nested.declaredPixelSize, MediaPixelSize(width: 1920, height: 1080))

        // An id that merely contains an "x", a size no video has, and a
        // platform that names nothing all answer the same way: nothing.
        for urlString in [
            "https://scontent.cdninstagram.com/v/t50/abcx123/reel.mp4",
            "https://cdn.example.com/2x3/clip.mp4",
            "https://www.tiktok.com/aweme/v1/play/?video_id=7000",
        ] {
            XCTAssertNil(
                MediaAsset(url: URL(string: urlString)!, kind: .video).declaredPixelSize,
                "invented a size for \(urlString)")
        }
    }

    // MARK: - Reddit keeps its pill

    /// Reddit's own injection path must keep using the plain hand-off target.
    /// Its video and audio are separate DASH streams (`MediaMuxer`'s whole
    /// reason for existing), so an in-page `<video>` handed the video URL would
    /// play it silently.
    func testTheRedditPathStillUsesThePlainHandoff() {
        XCTAssertTrue(
            contentScript.contains("function evaluateRedditPage(resp) {"),
            "the Reddit branch moved — re-check that it still bypasses the overlay")
        let redditBranch = contentScript.components(separatedBy: "function evaluateRedditPage(resp) {")
            .last ?? ""
        let untilNextFunction = redditBranch.components(separatedBy: "\n    function ").first ?? ""
        XCTAssertTrue(
            untilNextFunction.contains("downloadTargetFor(resp)"),
            "evaluateRedditPage must keep building the plain hand-off target")
        XCTAssertFalse(
            untilNextFunction.contains("videoOverlayTargetFor"),
            "Reddit must not enter the in-page player: its audio is a separate stream")
    }

    /// The overlay is offered from exactly one place — the non-Reddit platform
    /// branch of `offerLunaButton`.
    func testTheOverlayIsOfferedFromExactlyOnePillDecision() {
        let uses = contentScript.components(separatedBy: "videoOverlayTargetFor(").count - 1
        // The declaration, plus the one call site.
        XCTAssertEqual(
            uses, 2,
            "videoOverlayTargetFor should be declared once and called once — a second call "
                + "site is a page kind quietly gaining a player")
    }
}
