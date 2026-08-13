//
//  AppReaderShareProviderTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Which share options `AppReaderShareProvider` offers for a given saved item —
/// specifically the "Export as…" gate, which must appear only for an article
/// whose text is actually extracted (see claudedocs/article-export.md).
final class AppReaderShareProviderTests: XCTestCase {

    private var presenter: UIViewController!

    override func setUp() {
        super.setUp()
        presenter = UIViewController()
    }

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    private func seed(
        urlString: String, state: SavedItem.State,
        contentPlatform: ContentPlatform? = nil, withContent: Bool = true
    ) {
        let item = SavedItem(
            seed: "share-provider",
            urlString: urlString,
            title: "Shareable",
            dateAdded: Date(),
            state: state,
            platform: contentPlatform)
        let contents = withContent
            ? [item.id: UITestFixtures.sampleArticleContent(title: "Shareable")]
            : [:]
        SavesStore.shared.seedForTesting(items: [item], contents: contents)
    }

    @MainActor
    private func menuTitles(for urlString: String) -> [String] {
        let menu = AppReaderShareProvider.shared.shareMenu(
            urlString: urlString, title: "Shareable",
            from: presenter, sourceView: presenter.view)
        return (menu?.children ?? []).map(\.title)
    }

    @MainActor
    func testReadyArticleOffersEveryExportFormat() {
        seed(urlString: "https://example.com/ready", state: .ready)
        let titles = menuTitles(for: "https://example.com/ready")
        XCTAssertEqual(titles.last, "Export as…", "\(titles)")

        let menu = AppReaderShareProvider.shared.shareMenu(
            urlString: "https://example.com/ready", title: "Shareable",
            from: presenter, sourceView: presenter.view)
        let submenu = menu?.children.last as? UIMenu
        XCTAssertEqual(submenu?.children.count, ArticleExportFormat.shareMenuFormats.count)
    }

    /// A pending, failed or still-locked save has no extracted text, so every
    /// format would fail — the option must not be offered at all.
    @MainActor
    func testUnreadyArticleOffersNoExport() {
        for state in [SavedItem.State.pending, .failed, .needsCaptcha] {
            seed(urlString: "https://example.com/\(state.rawValue)",
                 state: state, withContent: false)
            let titles = menuTitles(for: "https://example.com/\(state.rawValue)")
            XCTAssertFalse(titles.contains("Export as…"), "\(state): \(titles)")
            // The link-sharing options still stand — a locked save has a URL.
            XCTAssertEqual(titles, ["Copy link", "Share link", "Send as email"], "\(state)")
        }
    }

    @MainActor
    func testMediaItemOffersNoExport() {
        seed(urlString: "https://youtube.com/watch?v=abc", state: .ready,
             contentPlatform: .youtube)
        let titles = menuTitles(for: "https://youtube.com/watch?v=abc")
        XCTAssertFalse(titles.contains("Export as…"), "\(titles)")
    }
}
