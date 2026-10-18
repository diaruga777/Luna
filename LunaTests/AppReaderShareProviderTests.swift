//
//  AppReaderShareProviderTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// Pins which share options `AppReaderShareProvider` offers for a saved item.
/// The "Export as…" option must appear only for an article with extracted
/// text. See `claudedocs/article-export.md`.
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

    /// Menu-primary share buttons never invoke the sheet fallback when the
    /// provider returns nil. Imports must supply the formats in the menu itself.
    @MainActor
    func testImportedEmailAndDocumentOfferEveryFormatDirectly() throws {
        for urlString in ["lunamail://123", "lunadoc://123"] {
            seed(urlString: urlString, state: .ready)
            let menu = try XCTUnwrap(AppReaderShareProvider.shared.shareMenu(
                urlString: urlString, title: "Shareable",
                from: presenter, sourceView: presenter.view))
            XCTAssertEqual(menu.children.map(\.title),
                           ArticleExportFormat.shareMenuFormats.map(\.displayName))
            XCTAssertEqual(menu.children.compactMap { $0 as? UIAction }.count,
                           ArticleExportFormat.shareMenuFormats.count)
        }
    }

    @MainActor
    func testUnreadyImportsOfferNoExport() {
        for urlString in ["lunamail://123", "lunadoc://123"] {
            for state in [SavedItem.State.pending, .failed, .needsCaptcha] {
                seed(urlString: urlString, state: state, withContent: false)
                XCTAssertNil(AppReaderShareProvider.shared.shareMenu(
                    urlString: urlString, title: "Shareable",
                    from: presenter, sourceView: presenter.view), "\(urlString): \(state)")
            }
        }
    }

    /// A pending, failed, or locked save has no extracted text. It must not
    /// offer any export format.
    @MainActor
    func testUnreadyArticleOffersNoExport() {
        for state in [SavedItem.State.pending, .failed, .needsCaptcha] {
            seed(urlString: "https://example.com/\(state.rawValue)",
                 state: state, withContent: false)
            let titles = menuTitles(for: "https://example.com/\(state.rawValue)")
            XCTAssertFalse(titles.contains("Export as…"), "\(state): \(titles)")
            // A locked save still has a URL, so link-sharing stays offered.
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
