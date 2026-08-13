//
//  PendingSaveCardTests.swift
//  LunaTests
//

import LunaDesignSystem
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

/// A new save has no metadata yet. It must not briefly inherit the reader's
/// Untitled/globe treatment before ingestion determines what it actually is.
@MainActor
final class PendingSaveCardTests: XCTestCase {

    private var installedArticlePresenter: CardKindPresenting?

    override func setUp() {
        super.setUp()
        installedArticlePresenter = CardKindPresenters.article
        CardKindPresenters.article = ArticleCardPresenter()
        SavesStore.shared.seedForTesting(items: [], contents: [:])
    }

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        CardKindPresenters.article = installedArticlePresenter
        super.tearDown()
    }

    func testPendingSaveUsesOnlyTheLoadingCardAndSuppressesMetadata() throws {
        var item = SavedItem(urlString: "https://example.com/new-save")
        // Proves even stale/upstream placeholder text cannot leak into the UI.
        item.title = "Untitled"
        SavesStore.shared.seedForTesting(items: [item], contents: [:])

        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()
        deck.carousel.reloadData(centeringAt: deck.cardOffset)

        let card = try XCTUnwrap(
            deck.carousel.contentController(at: deck.cardOffset)
                as? PendingSaveCardContentViewController)
        card.loadViewIfNeeded()
        XCTAssertEqual(card.loadingTextForTesting, "Loading...")
        XCTAssertTrue(card.isSpinnerAnimatingForTesting)

        let dataSource = try XCTUnwrap(deck.carousel.dataSource)
        XCTAssertNil(dataSource.carousel(deck.carousel, titleForCardAt: deck.cardOffset))

        var thumbnail: UIImage?
        dataSource.carousel(deck.carousel, loadThumbnailForCardAt: deck.cardOffset) {
            thumbnail = $0
        }
        XCTAssertNil(thumbnail)

        var badge: CarouselSourceBadge?
        dataSource.carousel(deck.carousel, loadSourceBadgeForCardAt: deck.cardOffset) {
            badge = $0
        }
        XCTAssertNil(badge)
        _ = window
    }
}
