//
//  SafariRedditGatingTests.swift
//  LunaTests
//

import WebKit
import XCTest

/// Exercises the Reddit post-page + media gating in `LunaSafari/Resources/content.js`
/// through the same bare-`WKWebView` harness as `SafariArticleHeuristicTests`: the
/// raw script is loaded into a plain web view (no extension host, no `browser`
/// global) and the test-only hooks it exposes are called —
/// `window.__lunaRedditPostID(urlString)` for URL gating (a subreddit / home feed /
/// comment-history listing must NOT read as a post) and
/// `window.__lunaRedditPostHasMedia()` for the media gate (only image/video/gallery
/// posts should get a "Download in Luna" pill).
@MainActor
final class SafariRedditGatingTests: XCTestCase {

    /// `LunaTests/SafariRedditGatingTests.swift` -> repo root -> `LunaSafari/Resources/content.js`.
    private static let contentScriptSource: String = {
        let thisFile = URL(fileURLWithPath: #filePath)
        let repoRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
        let scriptURL = repoRoot.appendingPathComponent("LunaSafari/Resources/content.js")
        return (try? String(contentsOf: scriptURL, encoding: .utf8)) ?? ""
    }()

    override func setUp() {
        super.setUp()
        XCTAssertFalse(
            Self.contentScriptSource.isEmpty,
            "content.js not found on disk -- check the path relative to #filePath")
    }

    // MARK: - Harness

    /// Loads `html` at `urlString`, evaluates content.js, then evaluates `expression`
    /// and returns the raw JS result.
    @MainActor
    private func evaluate(_ expression: String, html: String, urlString: String) -> Any? {
        let expectation = expectation(description: "js evaluated")
        var outcome: Any?

        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        let delegate = LoadDelegate {
            webView.evaluateJavaScript(Self.contentScriptSource) { _, error in
                if let error { XCTFail("content.js failed to evaluate: \(error)") }
                webView.evaluateJavaScript(expression) { result, error in
                    if let error { XCTFail("\(expression) failed to evaluate: \(error)") }
                    outcome = result
                    expectation.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(html, baseURL: URL(string: urlString))

        wait(for: [expectation], timeout: 10)
        withExtendedLifetime(delegate) {}
        return outcome
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void
        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { onFinish() }
    }

    /// The post id `content.js` parses out of `url`, or nil. Parses the URL string
    /// directly (independent of the harness's `location`).
    private func redditPostID(_ url: String) -> String? {
        let result = evaluate(
            "window.__lunaRedditPostID(\"\(url)\")",
            html: "<html><body></body></html>",
            urlString: "https://example.com/")
        return result as? String
    }

    /// The media verdict for `html` loaded at a reddit post permalink.
    private func hasMedia(_ html: String, urlString: String = "https://www.reddit.com/r/pics/comments/1abc2d/title/") -> Bool {
        let result = evaluate("window.__lunaRedditPostHasMedia()", html: html, urlString: urlString)
        return (result as? Bool) ?? false
    }

    // MARK: - URL gating (feeds/listings are NOT posts)

    func testFeedAndListingURLsAreNotPosts() {
        XCTAssertNil(redditPostID("https://www.reddit.com/"))
        XCTAssertNil(redditPostID("https://www.reddit.com/r/pics/"))
        XCTAssertNil(redditPostID("https://www.reddit.com/r/pics/top/"))
        // A subreddit literally named "comments" is still a feed.
        XCTAssertNil(redditPostID("https://www.reddit.com/r/comments/top/"))
        // A user's comment-history listing (no post id) is not a post.
        XCTAssertNil(redditPostID("https://www.reddit.com/user/spez/comments/"))
    }

    func testPostAndGalleryURLsAreItems() {
        XCTAssertEqual(redditPostID("https://www.reddit.com/r/pics/comments/1abc2d/title/"), "1abc2d")
        XCTAssertEqual(redditPostID("https://www.reddit.com/comments/1abc2d"), "1abc2d")
        XCTAssertEqual(redditPostID("https://www.reddit.com/user/spez/comments/1abc2d/title/"), "1abc2d")
        XCTAssertEqual(redditPostID("https://www.reddit.com/gallery/1abc2d"), "1abc2d")
        XCTAssertEqual(redditPostID("https://redd.it/1abc2d"), "1abc2d")
    }

    // MARK: - Media gating (image/video only)

    func testImagePostHasMedia() {
        XCTAssertTrue(hasMedia("<html><body><shreddit-post post-type=\"image\"></shreddit-post></body></html>"))
    }

    func testVideoPostHasMedia() {
        XCTAssertTrue(hasMedia("<html><body><shreddit-post post-type=\"video\"></shreddit-post></body></html>"))
    }

    func testTextPostHasNoMedia() {
        XCTAssertFalse(hasMedia("<html><body><shreddit-post post-type=\"text\"></shreddit-post></body></html>"))
    }

    func testLinkPostHasNoMedia() {
        XCTAssertFalse(hasMedia("<html><body><shreddit-post post-type=\"link\"></shreddit-post></body></html>"))
    }

    /// Old-reddit fallback: a post row whose `data-domain` is a reddit image host.
    func testOldRedditImagePostHasMedia() {
        let html = """
        <html><body><div id="siteTable">
        <div class="thing id-t3_1abc2d link" data-domain="i.redd.it"><a class="thumbnail"></a></div>
        </div></body></html>
        """
        XCTAssertTrue(hasMedia(html, urlString: "https://old.reddit.com/r/pics/comments/1abc2d/title/"))
    }

    func testEmptyDOMHasNoMedia() {
        XCTAssertFalse(hasMedia("<html><body></body></html>"))
    }
}
