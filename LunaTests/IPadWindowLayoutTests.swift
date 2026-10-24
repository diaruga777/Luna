import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna
@testable import LunaReaderUI

@MainActor
final class IPadWindowLayoutTests: XCTestCase {
    func testEmptyLibraryCentersWelcomeAndRestoresGridWhenSaveArrives() throws {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        defer { SavesStore.shared.seedForTesting(items: [], contents: [:]) }
        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(deck, size: CGSize(width: 1024, height: 1366))
        defer { window.isHidden = true }
        XCTAssertFalse(deck.carousel.usesReaderGrid)
        let card = try XCTUnwrap(deck.carousel.cardView(at: 0))
        let frame = card.convert(card.bounds, to: deck.view)
        XCTAssertEqual(frame.midX, deck.view.bounds.midX, accuracy: 1)
        XCTAssertGreaterThan(frame.width, 400)

        let item = SavedItem(seed: "ipad-grid", urlString: "https://example.com/ipad", title: "iPad", dateAdded: Date(), state: .ready, wordCount: 480)
        SavesStore.shared.seedForTesting(items: [item], contents: [item.id: UITestFixtures.sampleArticleContent(title: "iPad")])
        deck.reload()
        deck.view.layoutIfNeeded()
        deck.carousel.view.layoutIfNeeded()
        XCTAssertTrue(deck.carousel.usesReaderGrid)
    }

    func testSpeedReaderFontFollowsColumnWidthAfterResize() throws {
        let item = SavedItem(seed: "ipad-rsvp", urlString: "https://example.com/ipad-rsvp", title: "Sizing", dateAdded: Date(), state: .ready, wordCount: 480)
        let reader = RSVPViewController(item: item, content: UITestFixtures.sampleArticleContent(title: "Sizing"), initialDisplayMode: .words)
        let window = UITestSupport.host(reader, size: CGSize(width: 1024, height: 1000))
        defer { window.isHidden = true }
        // The word is the only directly hosted, attributed, monospaced label.
        let word = try XCTUnwrap(reader.view.subviews.compactMap { $0 as? UILabel }.first {
            $0.attributedText != nil && $0.font.fontDescriptor.symbolicTraits.contains(.traitMonoSpace)
        })
        let wideSize = word.font.pointSize
        reader.view.frame.size.width = 320
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        XCTAssertLessThan(word.font.pointSize, wideSize)
        reader.view.frame.size.width = 1024
        reader.view.setNeedsLayout()
        reader.view.layoutIfNeeded()
        XCTAssertEqual(word.font.pointSize, wideSize, accuracy: 0.1)
    }
}
