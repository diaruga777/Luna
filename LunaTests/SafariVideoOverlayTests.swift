//
//  SafariVideoOverlayTests.swift
//  LunaTests
//

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
        js.load(urlString: Self.pageURL)
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
        let link = try XCTUnwrap(LunaDeepLink.resolvedMediaLink(scheme: LunaDeepLink.downloaderScheme))
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

    func testFirstDirectlyPlayableSkipsStillsInACarousel() {
        let carousel = [
            MediaAsset(url: URL(string: "https://cdn.example.com/1.jpg")!, kind: .image),
            MediaAsset(url: URL(string: "https://cdn.example.com/2.mp4")!, kind: .video),
        ]
        XCTAssertEqual(carousel.firstDirectlyPlayable?.url.absoluteString, "https://cdn.example.com/2.mp4")
        XCTAssertNil([MediaAsset]().firstDirectlyPlayable)
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
