//
//  NewSaveCenteringTests.swift
//  LunaTests
//
//  Every deck moves to a save it has never shown, whenever and however that
//  save arrived: typed into the paste card here, dropped in by the share/action
//  extension, an App Intent, Safari, the mailbox importer, or a sibling app
//  writing the shared store while this one was suspended. The decks share one
//  seam for it — `CardCarouselHostViewController.newSaveItemIndex` — which
//  compares each reload's ids against the previous snapshot instead of asking
//  every entry point to announce itself.
//

import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class NewSaveCenteringTests: XCTestCase {

    private final class TestHost: CardCarouselHostViewController {}

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
    }

    override func tearDown() {
        ReadingListStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    // MARK: - The shared seam

    /// The deck has shown nothing yet, so nothing on it is "new" — the first
    /// snapshot only seeds, and the deck's own newest-first default already
    /// opens on the most recent save.
    func testFirstSnapshotSeedsWithoutCentering() {
        let host = TestHost()
        XCTAssertNil(host.newSaveItemIndex(cardIDs: [.init(), .init(), .init()]))
    }

    func testASaveThatArrivedSinceTheLastSnapshotIsCentered() {
        let host = TestHost()
        let existing = [UUID(), UUID()]
        XCTAssertNil(host.newSaveItemIndex(cardIDs: existing))

        let fresh = UUID()
        XCTAssertEqual(
            host.newSaveItemIndex(cardIDs: [fresh] + existing), 0,
            "a newly seen id centers, wherever the save came from")
    }

    /// Decks are newest-first, so the first unseen id in card order is the most
    /// recent of a batch — several saves landing while the app was away center
    /// on the newest one.
    func testABatchOfNewSavesCentersOnTheNewest() {
        let host = TestHost()
        let existing = [UUID()]
        XCTAssertNil(host.newSaveItemIndex(cardIDs: existing))

        let newest = UUID()
        let older = UUID()
        XCTAssertEqual(host.newSaveItemIndex(cardIDs: [newest, older] + existing), 0)
    }

    /// Nothing arrived; the deck keeps whatever card the reload preserved.
    func testAnUnchangedSnapshotCentersNothing() {
        let host = TestHost()
        let existing = [UUID(), UUID()]
        XCTAssertNil(host.newSaveItemIndex(cardIDs: existing))
        XCTAssertNil(host.newSaveItemIndex(cardIDs: existing))
    }

    /// Unarchiving puts a known id back on the deck. It is a card the user
    /// already had, not a new save — the archive tray's own transition owns
    /// where that lands.
    func testUnarchivingAKnownItemIsNotANewSave() {
        let host = TestHost()
        let onDeck = UUID()
        let archived = UUID()
        XCTAssertNil(host.newSaveItemIndex(cardIDs: [onDeck], offstageIDs: [archived]))

        XCTAssertNil(host.newSaveItemIndex(cardIDs: [archived, onDeck]))
    }

    /// The mirror image: archiving a card drops it from the deck, and the
    /// remaining ids are all still known.
    func testArchivingACardIsNotANewSave() {
        let host = TestHost()
        let kept = UUID()
        let archived = UUID()
        XCTAssertNil(host.newSaveItemIndex(cardIDs: [archived, kept]))

        XCTAssertNil(host.newSaveItemIndex(cardIDs: [kept], offstageIDs: [archived]))
    }

    // MARK: - The article deck, end to end

    /// The user is parked on the second card when a save lands in the shared
    /// store from somewhere else entirely. The deck reloads on
    /// `.readingListChanged` — the notification every surface's write funnels
    /// into, including `sceneWillEnterForeground`'s catch-up post — and must
    /// come to rest on the new card rather than the one it was holding.
    @MainActor
    func testArticleDeckMovesToASaveMadeElsewhere() {
        let seeded = seedArticles(count: 3)
        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 1)
        XCTAssertEqual(deck.carousel.currentIndex, 1)

        seedArticles(count: 1, seedPrefix: "elsewhere", startingAt: Date(), existing: seeded)
        NotificationCenter.default.post(name: .readingListChanged, object: nil)

        XCTAssertEqual(
            deck.carousel.currentIndex, 1,
            "a save made outside the app takes the center from the card the user was on")
        _ = window
    }

    /// The Reader must not depend on an extension's in-process notification:
    /// those posts never cross the process boundary. Foregrounding itself is
    /// therefore a reload trigger, and the root deck must move from the card
    /// the user last navigated to the item saved while it was suspended.
    @MainActor
    func testArticleDeckMovesToABackgroundSaveWhenForegrounded() {
        let seeded = seedArticles(count: 3)
        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 2)
        XCTAssertEqual(deck.carousel.currentIndex, 2)

        seedArticles(
            count: 1,
            seedPrefix: "saved-in-background",
            startingAt: Date().addingTimeInterval(60),
            existing: seeded)
        NotificationCenter.default.post(name: UIApplication.willEnterForegroundNotification, object: nil)

        XCTAssertEqual(
            deck.carousel.currentIndex, 1,
            "foregrounding must center the item saved while the app was suspended")
        _ = window
    }

    /// The already-shown cards keep their own centering rules: a store change
    /// that adds nothing (here, a title edit) leaves the user where they were.
    @MainActor
    func testArticleDeckStaysPutWhenNothingNewArrived() throws {
        var seeded = seedArticles(count: 3)
        let deck = ArticleCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 2)
        XCTAssertEqual(deck.carousel.currentIndex, 2)

        seeded[0].title = "Retitled"
        ReadingListStore.shared.seedForTesting(items: seeded, contents: contents(for: seeded))
        NotificationCenter.default.post(name: .readingListChanged, object: nil)

        XCTAssertEqual(deck.carousel.currentIndex, 2)
        _ = window
    }

    // MARK: - The price deck, end to end

    @MainActor
    func testPriceDeckMovesToATrackerSavedElsewhere() {
        let seeded = UITestSupport.seedSharedStore(.priceTracking)
        let deck = PriceTrackerCardsViewController()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 1)
        XCTAssertEqual(deck.carousel.currentIndex, 1)

        let url = "https://store.example.com/tracked-elsewhere"
        let tracked = ReadingListItem(
            seed: "pt-elsewhere", urlString: url, title: "Elsewhere Lamp",
            dateAdded: Date().addingTimeInterval(60), state: .ready,
            captureSource: .manual,
            priceTracker: PriceTracker(
                productName: "Elsewhere Lamp", firstStoreURL: url, price: 42,
                currency: "USD", brand: "Acme", productID: "pt-elsewhere"))
        ReadingListStore.shared.seedForTesting(
            items: [tracked] + seeded, contents: [:])
        NotificationCenter.default.post(name: .readingListChanged, object: nil)

        XCTAssertEqual(deck.carousel.currentIndex, 1)
        _ = window
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedArticles(
        count: Int,
        seedPrefix: String = "new-save",
        startingAt date: Date = Date(),
        existing: [ReadingListItem] = []
    ) -> [ReadingListItem] {
        var items = existing
        for offset in 0..<count {
            items.append(ReadingListItem(
                seed: "\(seedPrefix)-\(offset)",
                urlString: "https://example.com/\(seedPrefix)-\(offset)",
                title: "\(seedPrefix) \(offset)",
                dateAdded: date.addingTimeInterval(TimeInterval(-offset * 60)),
                state: .ready,
                readState: .unopened,
                wordCount: 480))
        }
        ReadingListStore.shared.seedForTesting(items: items, contents: contents(for: items))
        return items
    }

    private func contents(for items: [ReadingListItem]) -> [UUID: ArticleContent] {
        Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, UITestFixtures.sampleArticleContent(title: $0.title ?? "Article"))
        })
    }
}
