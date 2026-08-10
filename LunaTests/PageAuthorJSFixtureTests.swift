//
//  PageAuthorJSFixtureTests.swift
//  LunaTests
//

import XCTest

/// `content.js`'s `pageAuthor()` — the creator the Download hand-off carries to
/// the app so a saved row needs no metadata fetch
/// (`PendingResolvedMediaDownloads.completeFromHandoff`).
///
/// The YouTube fixture is the real markup a watch page ships (verified against a
/// live fetch: `<span itemprop="author"><link itemprop="name" content="Blender">`),
/// and the X fixture is that platform's rendered byline. The last two are the
/// cases that must yield NOTHING — the whole design rests on an empty answer
/// staying empty rather than becoming a guess.
@MainActor
final class PageAuthorJSFixtureTests: XCTestCase {

    private lazy var js = SafariJSTestHarness(self)

    private func author(html: String, urlString: String) -> String {
        js.load(html: html, urlString: urlString, scripts: [
            SafariJSTestHarness.newsHosts,
            SafariJSTestHarness.productRules,
            SafariJSTestHarness.platformHosts,
            SafariJSTestHarness.contentScript,
        ])
        return js.string("window.__lunaPageAuthor()") ?? ""
    }

    func testYouTubeWatchPageMicrodataYieldsTheChannel() {
        let html = """
        <meta itemprop="identifier" content="aqz-KE-bpKQ">
        <span itemprop="author" itemscope itemtype="http://schema.org/Person">
          <link itemprop="url" href="http://www.youtube.com/@BlenderOfficial">
          <link itemprop="name" content="Blender">
        </span>
        """
        XCTAssertEqual(author(html: html, urlString: "https://www.youtube.com/watch?v=aqz-KE-bpKQ"),
                       "Blender")
    }

    func testJSONLDVideoObjectAuthorYields() {
        let html = """
        <script type="application/ld+json">
        {"@type":"VideoObject","name":"A clip",
         "author":{"@type":"Person","name":"Ada Lovelace"}}
        </script>
        """
        XCTAssertEqual(author(html: html, urlString: "https://video.example/watch/1"),
                       "Ada Lovelace")
    }

    func testAuthorMetaYields() {
        let html = #"<meta name="author" content="  Grace   Hopper ">"#
        XCTAssertEqual(author(html: html, urlString: "https://news.example/story"),
                       "Grace Hopper")
    }

    func testXPostBylineYieldsTheDisplayNameNotTheHandle() {
        let html = """
        <article>
          <div data-testid="User-Name">
            <a href="/Blender"><span>Blender</span></a>
            <a href="/Blender"><span>@Blender</span></a>
          </div>
        </article>
        """
        XCTAssertEqual(author(html: html, urlString: "https://x.com/Blender/status/1758099513234784311"),
                       "Blender")
    }

    /// That byline reader is the ONE platform-specific one, so it must not fire
    /// on a page that merely happens to use the same test id.
    func testUserNameBylineIsNotReadOffAForeignHost() {
        let html = #"<div data-testid="User-Name"><span>Somebody Else</span></div>"#
        XCTAssertEqual(author(html: html, urlString: "https://video.example/watch/2"), "")
    }

    /// `article:author` overwhelmingly holds a profile LINK, and a link is not a
    /// name — turning one into a name means guessing which path component is a
    /// person.
    func testAuthorMetaHoldingAURLIsRefused() {
        let html = #"<meta property="article:author" content="https://facebook.com/some.page">"#
        XCTAssertEqual(author(html: html, urlString: "https://news.example/story-2"), "")
    }

    /// A page with a title, a site name and an og:image still states no AUTHOR.
    /// Nothing may be inferred from those.
    func testPageWithNoAuthorSignalYieldsNothing() {
        let html = """
        <title>A video — Example</title>
        <meta property="og:title" content="A video">
        <meta property="og:site_name" content="Example">
        <meta property="og:image" content="https://cdn.example/poster.jpg">
        """
        XCTAssertEqual(author(html: html, urlString: "https://video.example/watch/3"), "")
    }
}
