//
//  SafariRedditGatingTests.swift
//  LunaTests
//

import XCTest

/// Exercises the Reddit post-page + media gating in `LunaSafari/Resources/content.js`
/// through the shared bare-`WKWebView` harness (`SafariJSTestHarness`): the raw
/// script is loaded into a plain web view (no extension host, no `browser`
/// global) and the test-only hooks it exposes are called —
/// `window.__lunaRedditPostID(urlString)` for URL gating (a subreddit / home feed /
/// comment-history listing must NOT read as a post) and
/// `window.__lunaRedditPostHasMedia()` for the media gate (only animated image/video
/// posts should get a "Download in Luna" pill; static images should not).
@MainActor
final class SafariRedditGatingTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    // MARK: - Harness

    /// Loads `html` at `urlString`, evaluates content.js, then evaluates `expression`
    /// and returns the raw JS result.
    private func evaluate(_ expression: String, html: String, urlString: String) -> Any? {
        js.load(html: html, urlString: urlString, scripts: [SafariJSTestHarness.contentScript])
        return js.evaluate(expression)
    }

    /// The post ids `content.js` parses out of `urls` (nil where it sees no post).
    /// The hook takes the URL as an ARGUMENT, so every URL in a table is answered
    /// from ONE loaded document.
    private func redditPostIDs(_ urls: [String]) -> [String?] {
        js.load(
            html: "<html><body></body></html>", urlString: "https://example.com/",
            scripts: [SafariJSTestHarness.contentScript])
        return urls.map {
            js.evaluate("window.__lunaRedditPostID(\(SafariJSTestHarness.jsString($0)))") as? String
        }
    }

    /// The media verdict for `html` loaded at a reddit post permalink.
    private func hasMedia(_ html: String, urlString: String = "https://www.reddit.com/r/pics/comments/1abc2d/title/") -> Bool {
        (evaluate("window.__lunaRedditPostHasMedia()", html: html, urlString: urlString) as? Bool)
            ?? false
    }

    /// The media verdict for a modern `shreddit-post` of `postType`.
    private func hasMedia(postType: String) -> Bool {
        hasMedia("<html><body><shreddit-post post-type=\"\(postType)\"></shreddit-post></body></html>")
    }

    /// An old-reddit post row (`data-domain`, optional `data-url`) at `urlString`.
    private func oldRedditHasMedia(
        domain: String, dataURL: String? = nil, urlString: String
    ) -> Bool {
        let dataURLAttribute = dataURL.map { " data-url=\"\($0)\"" } ?? ""
        return hasMedia(
            """
            <html><body><div id="siteTable">
            <div class="thing id-t3_1abc2d link" data-domain="\(domain)"\(dataURLAttribute)>
            <a class="thumbnail"></a></div>
            </div></body></html>
            """,
            urlString: urlString)
    }

    /// The generic Downloader pill verdict for non-Reddit platform pages.
    private func shouldShowDownloadPill(
        _ html: String,
        platform: String = "instagram",
        urlString: String = "https://www.instagram.com/p/abc123/"
    ) -> Bool {
        let result = evaluate(
            "window.__lunaShouldShowDownloadPillForPlatform(\"\(platform)\")",
            html: html,
            urlString: urlString)
        return (result as? Bool) ?? false
    }

    // MARK: - URL gating (feeds/listings are NOT posts)

    func testFeedAndListingURLsAreNotPosts() {
        let feeds = [
            "https://www.reddit.com/",
            "https://www.reddit.com/r/pics/",
            "https://www.reddit.com/r/pics/top/",
            // A subreddit literally named "comments" is still a feed.
            "https://www.reddit.com/r/comments/top/",
            // A user's comment-history listing (no post id) is not a post.
            "https://www.reddit.com/user/spez/comments/",
        ]
        for (url, id) in zip(feeds, redditPostIDs(feeds)) {
            XCTAssertNil(id, url)
        }
    }

    func testPostAndGalleryURLsAreItems() {
        let posts = [
            "https://www.reddit.com/r/pics/comments/1abc2d/title/",
            "https://www.reddit.com/comments/1abc2d",
            "https://www.reddit.com/user/spez/comments/1abc2d/title/",
            "https://www.reddit.com/gallery/1abc2d",
            "https://redd.it/1abc2d",
        ]
        for (url, id) in zip(posts, redditPostIDs(posts)) {
            XCTAssertEqual(id, "1abc2d", url)
        }
    }

    // MARK: - Media gating (animated image/video only)

    /// Only animated image/video posts earn the pill. A static image, a gallery
    /// with no animated signal, a text post and a link post do not.
    func testModernRedditPostTypeMediaGate() {
        let expected: [(postType: String, hasMedia: Bool)] = [
            ("image", false), ("video", true), ("gif", true),
            ("gallery", false), ("text", false), ("link", false),
        ]
        for (postType, expectation) in expected {
            XCTAssertEqual(hasMedia(postType: postType), expectation, postType)
        }
        XCTAssertFalse(hasMedia("<html><body></body></html>"), "an empty DOM has no media")
    }

    /// Old-reddit fallback: the post row's `data-domain` (and `data-url` extension)
    /// stands in for `shreddit-post`'s type attribute.
    func testOldRedditPostRowMediaGate() {
        XCTAssertFalse(
            oldRedditHasMedia(
                domain: "i.redd.it",
                urlString: "https://old.reddit.com/r/pics/comments/1abc2d/title/"),
            "a reddit static-image host is not media")
        XCTAssertTrue(
            oldRedditHasMedia(
                domain: "v.redd.it",
                urlString: "https://old.reddit.com/r/videos/comments/1abc2d/title/"))
        XCTAssertTrue(
            oldRedditHasMedia(
                domain: "i.imgur.com", dataURL: "https://i.imgur.com/abc.gif",
                urlString: "https://old.reddit.com/r/gifs/comments/1abc2d/title/"),
            "an animated image URL is media")
    }

    // MARK: - Non-Reddit platform pill gating

    /// A platform post gets the Download pill unless the page says, specifically,
    /// that its only media is a STATIC image.
    func testNonRedditPlatformDownloadPillGate() {
        let staticImage = """
        <html><head>
        <meta property="og:type" content="article">
        <meta property="og:image" content="https://cdn.example.com/post.jpg">
        </head><body></body></html>
        """
        XCTAssertFalse(shouldShowDownloadPill(staticImage), "static image")

        let video = """
        <html><head>
        <meta property="og:type" content="video.other">
        <meta property="og:video" content="https://cdn.example.com/post.mp4">
        <meta property="og:image" content="https://cdn.example.com/post.jpg">
        </head><body></body></html>
        """
        XCTAssertTrue(shouldShowDownloadPill(video), "video")

        let animated = """
        <html><head>
        <meta property="og:image" content="https://cdn.example.com/post.gif">
        </head><body></body></html>
        """
        XCTAssertTrue(shouldShowDownloadPill(animated), "animated image")

        XCTAssertTrue(
            shouldShowDownloadPill("<html><body><p>Post text</p></body></html>"),
            "no static-image signal at all")
    }

    /// Instagram serves a reel with exactly the markup a photo post gets — the
    /// `staticImage` fixture above IS a live reel's head, verbatim — so the
    /// meta-tag heuristics suppressed every reel's pill. `/reel|reels|tv/<code>`
    /// is a video-only surface, so the PATH settles it and the heuristics get no
    /// vote. `/p/` keeps them: it carries photos too.
    func testInstagramReelPathOverridesStaticImageHeuristic() {
        // Verbatim head of https://www.instagram.com/reel/DbwB-E1MYKt/ — no
        // og:video, no twitter:player, og:type "article", a JPG thumbnail.
        let reelPage = """
        <html><head>
        <meta property="og:type" content="article">
        <meta property="og:image" content="https://scontent.cdninstagram.com/v/t51.82787-15/769189704.jpg">
        <meta name="twitter:card" content="summary_large_image">
        <meta name="twitter:image" content="https://scontent.cdninstagram.com/v/t51.82787-15/769189704.jpg">
        </head><body></body></html>
        """
        let videoPaths = [
            "https://www.instagram.com/reel/DbwB-E1MYKt/",
            // Instagram's own og:url puts the author ahead of the media kind.
            "https://www.instagram.com/davi87dp/reel/DbwB-E1MYKt/",
            "https://www.instagram.com/reels/DbwB-E1MYKt/",
            "https://www.instagram.com/tv/DbwB-E1MYKt/",
        ]
        for url in videoPaths {
            XCTAssertTrue(shouldShowDownloadPill(reelPage, urlString: url), url)
        }

        // A photo post's markup is indistinguishable, so `/p/` must still be
        // decided by the heuristics — and suppressed.
        XCTAssertFalse(
            shouldShowDownloadPill(reelPage, urlString: "https://www.instagram.com/p/DbwB-E1MYKt/"),
            "a /p/ post with only a static-image signal stays suppressed")

        // The reels FEED is not a reel: no shortcode after the kind segment.
        XCTAssertFalse(
            shouldShowDownloadPill(reelPage, urlString: "https://www.instagram.com/reels/"),
            "the reels feed is not an item")

        // The override is Instagram-shaped, not a global path rule.
        XCTAssertFalse(
            shouldShowDownloadPill(
                reelPage, platform: "tiktok",
                urlString: "https://www.tiktok.com/reel/DbwB-E1MYKt/"),
            "another platform's /reel/ path is not covered")
    }
}
