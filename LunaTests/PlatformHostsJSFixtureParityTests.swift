//
//  PlatformHostsJSFixtureParityTests.swift
//  LunaTests
//

import LunaURLClassification
import WebKit
import XCTest

/// Runs a fixture URL matrix through BOTH `content.js`'s `recognizedPlatformPage`
/// (in a bare `WKWebView`, exactly as the real extension injects it -- see
/// `background.js`'s `injectContentScript`) and `PlatformRecognizer.recognize`,
/// and asserts they agree on every URL. `platform_hosts.generated.js` supplies the
/// host lists (guarded against drift from `PlatformRecognizer.rules` by
/// `PlatformHostsJSParityTests`); this test is what actually exercises the
/// path-shape logic (Bluesky's post-only requirement, Reddit's post/share-link
/// gate, host-suffix matching) that the generated file's raw host lists alone
/// can't verify. Includes the drift URLs from
/// `refactor-plans/audits/platform-matching.md`'s matrix, several of which used to
/// disagree before content.js was rewritten to consume the generated table.
@MainActor
final class PlatformHostsJSFixtureParityTests: XCTestCase {

    private static let contentScriptSource: String = resource("LunaSafari/Resources/content.js")
    private static let platformHostsSource: String = resource("LunaSafari/Resources/platform_hosts.generated.js")

    private static func resource(_ relativePath: String) -> String {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appendingPathComponent(relativePath)
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    override func setUp() {
        super.setUp()
        XCTAssertFalse(
            Self.contentScriptSource.isEmpty,
            "content.js not found on disk -- check the path relative to #filePath")
        XCTAssertFalse(
            Self.platformHostsSource.isEmpty,
            "platform_hosts.generated.js not found on disk -- generate it with "
            + "TEST_RUNNER_RECORD_PLATFORM_HOSTS=1")
    }

    /// Loads `platform_hosts.generated.js` THEN `content.js` into a WKWebView at
    /// `urlString` (mirroring background.js's real injection order), then evaluates
    /// `window.__lunaRecognizedPlatformPage()` and returns the result (nil for the
    /// JS `null`).
    @MainActor
    private func recognizedPlatform(at urlString: String) -> String? {
        let expectation = expectation(description: "recognizedPlatformPage evaluated for \(urlString)")
        var outcome: String?
        var evaluated = false

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.platformHostsSource) { _, error in
                if let error { XCTFail("platform_hosts.generated.js failed to evaluate: \(error)") }
                webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                    if let error { XCTFail("content.js failed to evaluate: \(error)") }
                    webView.evaluateJavaScript("window.__lunaRecognizedPlatformPage()") { result, error in
                        if let error { XCTFail("recognizedPlatformPage failed to evaluate: \(error)") }
                        outcome = result as? String
                        evaluated = true
                        expectation.fulfill()
                    }
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString("<html><body></body></html>", baseURL: URL(string: urlString))

        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        XCTAssertTrue(evaluated, "recognizedPlatformPage never returned for \(urlString)")
        return outcome
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    /// Asserts `content.js` and `PlatformRecognizer` agree on `urlString`.
    private func assertParity(_ urlString: String, file: StaticString = #filePath, line: UInt = #line) {
        let expected = PlatformRecognizer.recognize(urlString)?.platform.rawValue
        XCTAssertEqual(
            recognizedPlatform(at: urlString), expected,
            "content.js/PlatformRecognizer disagree on \(urlString)", file: file, line: line)
    }

    func testXURLs() {
        assertParity("https://x.com/jack/status/20")
        assertParity("https://mobile.twitter.com/user/status/123")
        // A subdomain outside XLink's old fixed host set -- PlatformRecognizer and
        // content.js both suffix-match ANY x.com/twitter.com subdomain.
        assertParity("https://some-other.twitter.com/user/status/123")
    }

    func testBlueskyURLs() {
        assertParity("https://bsky.app/profile/alice.bsky.social/post/3kxyz")
        // A bare profile (no /post/) must NOT recognize -- content.js used to
        // false-positive here on any "post" segment anywhere in the path.
        assertParity("https://bsky.app/profile/alice.bsky.social")
        assertParity("https://bsky.app/settings")
    }

    func testRedditURLs() {
        assertParity("https://www.reddit.com/")
        assertParity("https://www.reddit.com/r/pics/")
        assertParity("https://www.reddit.com/r/pics/comments/1abc2d/title/")
        assertParity("https://redd.it/1abc2d")
        // A direct redd.it media subdomain is a recognized reddit HOST but not a
        // POST -- must still classify as "not reddit" overall.
        assertParity("https://i.redd.it/abc.jpg")
        // Reddit's app-native share link -- content.js used to miss this entirely
        // (no share-token branch), silently falling through to article/product
        // heuristics instead of recognizing it as a Reddit item.
        assertParity("https://www.reddit.com/r/WhatsWrongWithYourDog/s/qRjWPbZ2bo")
        assertParity("https://www.reddit.com/r/pics/s/")
    }

    func testTikTokURLs() {
        assertParity("https://www.tiktok.com/@user/video/7212345678901234567")
        assertParity("https://vm.tiktok.com/ZM1234/")
    }

    func testInstagramURLs() {
        assertParity("https://www.instagram.com/reel/CxYz123/")
        // instagr.am -- content.js already covered this, unlike the dead
        // InstagramLink.isInstagram predicate that used to be instagram.com-only.
        assertParity("https://instagr.am/p/AbC123/")
    }

    func testFacebookURLs() {
        assertParity("https://www.facebook.com/watch/?v=123")
        assertParity("https://facebook.com/reel/456")
        assertParity("https://fb.watch/abcdef/")
        assertParity("https://m.facebook.com/watch/?v=123")
    }

    /// Spotify / Apple Music / Apple Podcasts are gone from content.js -- Swift has
    /// no such platforms, so identical behavior means the extension no longer
    /// offers a download the app cannot perform.
    func testRemovedAudioPlatformsNoLongerRecognize() {
        assertParity("https://open.spotify.com/track/abc123")
        assertParity("https://music.apple.com/us/album/example/123")
        assertParity("https://podcasts.apple.com/us/podcast/example/id123")
    }

    func testOrdinaryURLIsNotAPlatform() {
        assertParity("https://en.wikipedia.org/wiki/Swift")
    }
}
