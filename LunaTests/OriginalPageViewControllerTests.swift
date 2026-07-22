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
}
