//
//  NewSaveCenteringTests.swift
//  LunaTests
//
//  Every deck moves to a save it has never shown, whenever and however that
//  save arrived: typed into the util card here, dropped in by the share/action
//  or Safari extension, an App Intent, the mailbox importer, or a sibling app
//  writing the shared store while this one was suspended. All four apps' decks
//  are ONE implementation with one centering ladder, and a new save sits at the
//  top of it — above the parked card, above a pending interactive save, in every
//  app. The detection seam is `CardCarouselHostViewController.newSaveItemIndex`,
//  which compares each reload's ids against the previous snapshot instead of
//  asking every entry point to announce itself; nothing is gated on the save
//  having been made interactively.
//

import LunaMediaDownload
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
        SavedMediaDeckFixtures.emptySharedMediaStore()
    }

    override func tearDown() {
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        SavedMediaDeckFixtures.emptySharedMediaStore()
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
    /// `.savesChanged` — the notification every surface's write funnels
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
        NotificationCenter.default.post(name: .savesChanged, object: nil)

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
        SavesStore.shared.seedForTesting(items: seeded, contents: contents(for: seeded))
        NotificationCenter.default.post(name: .savesChanged, object: nil)

        XCTAssertEqual(deck.carousel.currentIndex, 2)
        _ = window
    }

    // MARK: - The price deck, end to end

    @MainActor
    func testPriceDeckMovesToATrackerSavedElsewhere() {
        let seeded = UITestSupport.seedSharedStore(.priceTracking)
        let deck = ProductCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 2)
        XCTAssertEqual(deck.carousel.currentIndex, 2)

        let url = "https://store.example.com/tracked-elsewhere"
        let tracked = SavedItem(
            seed: "pt-elsewhere", urlString: url, title: "Elsewhere Lamp",
            dateAdded: Date().addingTimeInterval(60), state: .ready,
            captureSource: .manual,
            priceTracker: PriceTracker(
                productName: "Elsewhere Lamp", firstStoreURL: url, price: 42,
                currency: "USD", brand: "Acme", productID: "pt-elsewhere"))
        SavesStore.shared.seedForTesting(
            items: [tracked] + seeded, contents: [:])
        NotificationCenter.default.post(name: .savesChanged, object: nil)

        XCTAssertEqual(
            deck.carousel.currentIndex, 1,
            "a tracker saved outside the app takes the center from the card the user was on")
        _ = window
    }

    // MARK: - The media deck, end to end

    /// The Downloader had no end-to-end case at all. Its rows are keyed by the
    /// MEDIA store's ids, so this also pins that the shared diff works on a deck
    /// whose slot ids come from somewhere other than the saves list.
    @MainActor
    func testMediaDeckMovesToASaveMadeElsewhere() {
        seedMedia(count: 3)
        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 2)
        XCTAssertEqual(deck.carousel.currentIndex, 2)

        seedMedia(count: 1, prefix: "elsewhere", startingAt: Date().addingTimeInterval(60))
        NotificationCenter.default.post(name: .savedMediaChanged, object: nil)

        XCTAssertEqual(
            deck.carousel.currentIndex, 1,
            "a media save made outside the app takes the center from the card the user was on")
        _ = window
    }

    /// A failed save is a card on this deck too, and one that arrives while the
    /// user is parked elsewhere is still a save that just arrived.
    @MainActor
    func testMediaDeckMovesToAFailedSaveThatJustArrived() {
        seedMedia(count: 2)
        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        deck.carousel.reloadData(centeringAt: 2)
        XCTAssertEqual(deck.carousel.currentIndex, 2)

        let broken = SavedItem(
            seed: "new-save-broken",
            urlString: "https://broken.example.com/new-save",
            title: nil,
            dateAdded: Date().addingTimeInterval(60),
            state: .failed)
        SavesStore.shared.seedForTesting(items: [broken], contents: [:])
        NotificationCenter.default.post(name: .savesChanged, object: nil)

        XCTAssertEqual(
            deck.slots[deck.carousel.currentIndex - deck.cardOffset].id, broken.id,
            "the deck comes to rest on the save that just arrived, broken or not")
        _ = window
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedMedia(
        count: Int,
        prefix: String = "new-save",
        startingAt date: Date = Date()
    ) -> [SavedMediaItem] {
        SavedMediaDeckFixtures.seedMedia(count: count, prefix: prefix, startingAt: date)
    }

    @discardableResult
    private func seedArticles(
        count: Int,
        seedPrefix: String = "new-save",
        startingAt date: Date = Date(),
        existing: [SavedItem] = []
    ) -> [SavedItem] {
        var items = existing
        for offset in 0..<count {
            items.append(SavedItem(
                seed: "\(seedPrefix)-\(offset)",
                urlString: "https://example.com/\(seedPrefix)-\(offset)",
                title: "\(seedPrefix) \(offset)",
                dateAdded: date.addingTimeInterval(TimeInterval(-offset * 60)),
                state: .ready,
                readState: .unopened,
                wordCount: 480))
        }
        SavesStore.shared.seedForTesting(items: items, contents: contents(for: items))
        return items
    }

    private func contents(for items: [SavedItem]) -> [UUID: ArticleContent] {
        Dictionary(uniqueKeysWithValues: items.map {
            ($0.id, UITestFixtures.sampleArticleContent(title: $0.title ?? "Article"))
        })
    }
}
