//
//  OriginalPageViewControllerTests.swift
//  LunaTests
//

import LunaArchiveReader
import LunaModels
import LunaStorage
import WebKit
import XCTest

final class OriginalPageViewControllerTests: XCTestCase {
    @MainActor
    func testWebArchiveReplayAllowsContentJavaScript() {
        let item = ReadingListItem(urlString: "https://example.com/script-laid-out-article")
        let controller = OriginalPageViewController(item: item, store: .shared)

        XCTAssertTrue(controller.allowsContentJavaScriptForTesting)
    }

    @MainActor
    func testNewYorkerArchiveReplayInstallsPaywallAndAdCleanup() throws {
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
    func testNewYorkerReplayKeepsArticleVisibleWhenPaywallArrivesLate() async throws {
        let url = try XCTUnwrap(URL(
            string: "https://www.newyorker.com/culture/the-weekend-essay/test"))
        let configuration = SavedArchiveWebConfiguration.make(for: url)
        await SavedArchiveWebConfiguration.prepare(configuration, for: url)
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 844), configuration: configuration)
        let evaluated = expectation(description: "late paywall cleaned")
        var outcome: String?
        let delegate = LoadDelegate {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                let expression = """
                (function () {
                  var articleDisplay = getComputedStyle(document.querySelector('#article')).display;
                  var wall = document.querySelector('#late-wall');
                  var wallHidden = !wall || getComputedStyle(wall).display === 'none';
                  return articleDisplay + '|' + wallHidden;
                })()
                """
                webView.evaluateJavaScript(expression) { result, error in
                    if let error { XCTFail("fixture expression failed: \(error)") }
                    outcome = result as? String
                    evaluated.fulfill()
                }
            }
        }
        webView.navigationDelegate = delegate
        webView.loadHTMLString(
            """
            <html><body>
              <article><p id="article" class="paywall">The complete saved article.</p></article>
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
            baseURL: url)

        await fulfillment(of: [evaluated], timeout: 5)
        withExtendedLifetime(delegate) {}
        XCTAssertEqual(outcome, "block|true")
    }

    @MainActor
    func testNewYorkerCapturePersistsRenderedCleanupStyle() async throws {
        let url = try XCTUnwrap(URL(
            string: "https://www.newyorker.com/culture/the-weekend-essay/test"))
        let prose = String(repeating: "Complete article prose remains available. ", count: 80)
        let html = """
        <html><head><title>Saved article</title></head><body>
        <aside class="paywall-bar">Subscribe</aside>
        <div class="ad-stickyhero">Advertisement</div>
        <article><p>\(prose)</p></article>
        </body></html>
        """

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
    }

    private final class LoadDelegate: NSObject, WKNavigationDelegate {
        private let onFinish: () -> Void

        init(onFinish: @escaping () -> Void) { self.onFinish = onFinish }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            onFinish()
        }
    }
}
