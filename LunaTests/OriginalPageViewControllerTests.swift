//
//  OriginalPageViewControllerTests.swift
//  LunaTests
//

@testable import LunaArchiveReader
import LunaModels
import LunaStorage
import WebKit
import XCTest

final class OriginalPageViewControllerTests: XCTestCase {
    @MainActor
    func testNewYorkerCaptureInstallsPaywallAndAdCleanup() throws {
        let url = try XCTUnwrap(URL(
            string: "https://www.newyorker.com/culture/the-weekend-essay/the-voice-of-google"))
        let configuration = SavedArchiveWebConfiguration.make(for: url)
        let sources = configuration.userContentController.userScripts.map(\.source)

        XCTAssertTrue(sources.contains { $0.contains("div.paywall") })
        XCTAssertTrue(sources.contains { $0.contains("aside.paywall-bar") })
        XCTAssertTrue(sources.contains { $0.contains("div.ad-stickyhero") })
        XCTAssertTrue(sources.contains { $0.contains("MutationObserver") })
    }

    @MainActor
    func testReplayNeverExecutesLatePublisherPaywall() async throws {
        let configuration = SavedArchiveWebConfiguration.makeReplayConfiguration()
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let loaded = expectation(description: "Saved page finished loading")
        var outcome: String?
        let delegate = LoadDelegate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                webView.evaluateJavaScript("""
                (function () {
                  var wall = document.querySelector('#late-wall');
                  return document.querySelector('#article').textContent + '|' + (wall === null);
                })()
                """) { result, _ in
                    outcome = result as? String
                    loaded.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            """
            <html><body>
              <article><p id="article">The complete saved article.</p></article>
              <script>
                setTimeout(function () {
                  var wall = document.createElement('aside');
                  wall.id = 'late-wall';
                  wall.className = 'PaywallModalWrapper-current paywall-modal';
                  wall.textContent = 'Subscribe to continue';
                  document.body.appendChild(wall);
                }, 150);
              </script>
            </body></html>
            """,
            baseURL: nil)

        // The assertion runs well past the publisher timer. The expectation also
        // bounds simulator WebContent launch failures instead of hanging the suite.
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(outcome, "The complete saved article.|true")
    }

    @MainActor
    func testNewYorkerCapturePersistsRenderedCleanupStyle() async throws {
        let url = try XCTUnwrap(URL(
            string: "https://www.newyorker.com/culture/the-weekend-essay/test"))
        let prose = String(repeating: "Complete article prose remains available. ", count: 80)
        let html = """
        <html><head><title>Saved article</title></head><body onload="window.publisherBooted=true">
        <aside class="paywall-bar">Subscribe</aside>
        <div class="ad-stickyhero">Advertisement</div>
        <article><p>\(prose)</p></article>
        <script>
          var renderedStyle = document.createElement('style');
          renderedStyle.textContent = '.layout-installed-by-script { margin: 17px; }';
          document.head.appendChild(renderedStyle);
          setTimeout(function () {
            document.body.innerHTML = '<aside class="paywall-modal">Subscribe</aside>';
          }, 5000);
        </script>
        </body></html>
        """

        // A fixture page's layout is stable on the first sample, so the settle
        // loop's shipped pacing of several seconds only wastes time here. The
        // loop still runs its full shape — first turn, three matching
        // signatures, the cap — just at a pace the test can afford.
        WebArchiveCapturer.settleFirstTurn = .milliseconds(5)
        WebArchiveCapturer.settlePollInterval = .milliseconds(5)
        defer {
            WebArchiveCapturer.settleFirstTurn = .milliseconds(500)
            WebArchiveCapturer.settlePollInterval = .milliseconds(250)
        }
        let captured = await WebArchiveCapturer.capture(html: html, baseURL: url)
        let archive = try XCTUnwrap(captured)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: archive, options: [], format: nil) as? [String: Any])
        let main = try XCTUnwrap(plist["WebMainResource"] as? [String: Any])
        let mainData = try XCTUnwrap(main["WebResourceData"] as? Data)
        let archivedHTML = try XCTUnwrap(String(data: mainData, encoding: .utf8))

        XCTAssertTrue(archivedHTML.contains("div.ad, aside.paywall-bar"))
        XCTAssertTrue(archivedHTML.contains("display:none !important"))
        XCTAssertTrue(archivedHTML.contains("Complete article prose remains available"))
        XCTAssertTrue(archivedHTML.contains("layout-installed-by-script"))
        XCTAssertTrue(archivedHTML.contains("luna-archive-safety"))
        XCTAssertFalse(archivedHTML.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(archivedHTML.contains("onload="))
    }

    func testArchiveSanitizerRemovesLegacyPublisherExecutionOnly() throws {
        let html = """
        <html><head>
          <style>.rendered-layout { display: grid; }</style>
          <meta http-equiv="refresh" content="1; https://example.com/live-paywall">
          <meta http-equiv="Content-Security-Policy" content="script-src *">
        </head><body onload="installWall()">
          <article><p>Captured readable prose.</p></article>
          <script>setTimeout(installWall, 1000)</script>
        </body></html>
        """
        let archive: [String: Any] = [
            "WebMainResource": [
                "WebResourceData": Data(html.utf8),
                "WebResourceFrameName": "",
                "WebResourceMIMEType": "text/html",
                "WebResourceTextEncodingName": "UTF-8",
                "WebResourceURL": "https://www.newyorker.com/story",
            ],
            "WebSubresources": [[
                "WebResourceData": Data("installWall()".utf8),
                "WebResourceMIMEType": "application/javascript",
                "WebResourceURL": "https://www.newyorker.com/publisher.js",
            ]],
        ]
        let data = try PropertyListSerialization.data(
            fromPropertyList: archive, format: .binary, options: 0)
        let sanitized = try XCTUnwrap(WebArchiveSanitizer.sanitized(data))
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(
                from: sanitized, options: [], format: nil) as? [String: Any])
        let main = try XCTUnwrap(plist["WebMainResource"] as? [String: Any])
        let mainData = try XCTUnwrap(main["WebResourceData"] as? Data)
        let result = try XCTUnwrap(String(data: mainData, encoding: .utf8))

        XCTAssertTrue(result.contains("Captured readable prose"))
        XCTAssertTrue(result.contains(".rendered-layout { display: grid; }"))
        XCTAssertTrue(result.contains("luna-archive-safety"))
        XCTAssertTrue(result.contains("background-color: Canvas"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("<script"))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("http-equiv=\"refresh\""))
        XCTAssertFalse(result.localizedCaseInsensitiveContains("content-security-policy"))
        XCTAssertFalse(result.contains("onload="))
        XCTAssertEqual((plist["WebSubresources"] as? [[String: Any]])?.count, 0)
    }

    func testArchiveReadabilityRejectsPublisherShellWithoutSavedArticle() throws {
        let articleText = String(
            repeating: "The complete article contains durable words about humane innovation. ",
            count: 40)
        let content = ArticleContent(
            title: "The Voice of Google",
            blocks: [.init(kind: .paragraph, text: articleText, links: [])])
        let shell = try archiveData(html: """
        <html><body><nav>News Books Culture Magazine Podcasts Shop</nav>
        <aside>Subscribe to continue reading this story.</aside></body></html>
        """)
        let full = try archiveData(html: """
        <html><body><article><p>\(articleText)</p></article></body></html>
        """)

        XCTAssertFalse(WebArchiveSanitizer.containsReadableArticle(shell, content: content))
        XCTAssertTrue(WebArchiveSanitizer.containsReadableArticle(full, content: content))
    }

    /// Paris Review regression: a live capture of a metered page holds the article's
    /// OPENING, so word overlap accepted it — the teaser's distinct vocabulary matched
    /// 68% of the words sampled from the END of the real 5,000-word interview. The
    /// gate has to be contiguous and spread across the article, or "Original" shows a
    /// truncated page under an un-dismissible subscribe card.
    func testArchiveReadabilityRejectsATeaserHoldingOnlyTheArticleOpening() throws {
        let paragraphs = (1...12).map { index in
            "Section \(index) of the interview turns to the discipline of the written "
            + "word, which punishes both stupidity and dishonesty in equal measure, and "
            + "he circles back to the loneliness that makes a writer send signals out."
        }
        let content = ArticleContent(
            title: "The Art of Fiction No. 45",
            blocks: paragraphs.map { .init(kind: .paragraph, text: $0, links: []) })
        let teaser = try archiveData(html: """
        <html><body><article><p>\(paragraphs[0])</p><p>\(paragraphs[1])</p></article>
        <div class="paywall"><h1>Want to keep reading? Subscribe and save 33%.</h1></div>
        </body></html>
        """)
        let whole = try archiveData(
            html: "<html><body><article>"
                + paragraphs.map { "<p>\($0)</p>" }.joined()
                + "</article></body></html>")

        XCTAssertFalse(WebArchiveSanitizer.containsReadableArticle(teaser, content: content),
                       "a capture holding only the opening is not the saved article")
        XCTAssertTrue(WebArchiveSanitizer.containsReadableArticle(whole, content: content))
    }

    /// The comparison ignores separators entirely, so the same passage still matches
    /// when the archive's DOM breaks its lines with markup (`<br>`, `&nbsp;`) that the
    /// saved blocks represent as ordinary spaces.
    func testArchiveReadabilitySurvivesDifferentWhitespaceMarkup() throws {
        let sentences = (1...6).map {
            "Line \($0) of the quoted passage runs long enough to be sampled verbatim by the readability gate."
        }
        let content = ArticleContent(
            title: "A Quoted Passage",
            blocks: sentences.map { .init(kind: .quote, text: $0, links: []) })
        let archive = try archiveData(
            html: "<html><body><article><blockquote>"
                + sentences.joined(separator: "<br><br>&nbsp;")
                + "</blockquote></article></body></html>")

        XCTAssertTrue(WebArchiveSanitizer.containsReadableArticle(archive, content: content))
    }

    func testSavedSnapshotIsSelfContainedAndDarkModeAware() throws {
        let linked = "Read the supporting source"
        let content = ArticleContent(
            title: "A <Saved> Story",
            author: "Claire & Co.",
            blocks: [
                .init(
                    kind: .paragraph,
                    text: linked,
                    links: [.init(start: 9, length: 17, urlString: "https://example.com?a=1&b=2")]),
            ])
        let html = SavedArticleSnapshotRenderer.html(
            content: content,
            sourceURL: URL(string: "https://www.newyorker.com/story"),
            imagesDirectory: FileManager.default.temporaryDirectory)

        XCTAssertTrue(html.contains("default-src 'none'"))
        XCTAssertTrue(html.contains("prefers-color-scheme: dark"))
        XCTAssertTrue(html.contains("--background: #000000"))
        XCTAssertTrue(html.contains("A &lt;Saved&gt; Story"))
        XCTAssertTrue(html.contains("Claire &amp; Co."))
        XCTAssertTrue(html.contains("href=\"https://example.com?a=1&amp;b=2\""))
    }

    @MainActor
    func testMissingArchiveLoadsLocalSnapshotInsteadOfPublisherURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("OriginalPageViewControllerTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let item = store.add(urlString: "https://www.newyorker.com/culture/test")
        let prose = String(repeating: "Readable saved article prose. ", count: 80)
        let saved = store.saveContent(
            ArticleContent(
                title: "Saved Story",
                blocks: [.init(kind: .paragraph, text: prose, links: [])]),
            for: item)
        let controller = OriginalPageViewController(item: saved, store: store)
        controller.overrideUserInterfaceStyle = .dark
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.loadedDocumentForTesting, "articleSnapshot")
        let webView = try XCTUnwrap(findWebView(in: controller.view))
        XCTAssertFalse(webView.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertNotEqual(webView.url, saved.url)
    }

    private func archiveData(html: String) throws -> Data {
        try PropertyListSerialization.data(
            fromPropertyList: [
                "WebMainResource": [
                    "WebResourceData": Data(html.utf8),
                    "WebResourceFrameName": "",
                    "WebResourceMIMEType": "text/html",
                    "WebResourceTextEncodingName": "UTF-8",
                    "WebResourceURL": "https://www.newyorker.com/story",
                ],
                "WebSubresources": [],
            ],
            format: .binary,
            options: 0)
    }

    @MainActor
    private func findWebView(in view: UIView) -> WKWebView? {
        if let webView = view as? WKWebView { return webView }
        for child in view.subviews {
            if let found = findWebView(in: child) { return found }
        }
        return nil
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish()
        }
    }
}
