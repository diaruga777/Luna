//
//  SavedMediaDeckSlotTests.swift
//  LunaTests
//
//  The Downloader's deck is the one whose cards come from TWO stores: its
//  media rows, then the saves whose ingestion failed (which carry no kind,
//  so every app shows them). Both are slots in the one list the shared host
//  owns, and these tests pin the consequences: a failed save must count as a
//  real card, and the tray's pull must never activate before the true last
//  one.
//

import LunaMediaDownload
import LunaModels
import LunaStorage
import UIKit
import XCTest
@testable import Luna

final class SavedMediaDeckSlotTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UIView.setAnimationsEnabled(false)
        SavedMediaDeckFixtures.emptySharedMediaStore()
    }

    override func tearDown() {
        SavedMediaDeckFixtures.emptySharedMediaStore()
        SavesStore.shared.seedForTesting(items: [], contents: [:])
        super.tearDown()
    }

    // MARK: - Failed saves are cards, so they are slots

    /// A failed save sits after the media rows, and the deck must count it.
    /// Feeding `canPull` only `items.count + cardOffset` — the last MEDIA
    /// card — would activate the archive tray's pull mid-deck, so the true
    /// last card could never open it.
    @MainActor
    func testCardCountIncludesFailedSavesAfterTheMediaRows() {
        seedMedia(count: 2)
        seedFailedSaves(count: 2)

        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        XCTAssertEqual(deck.slots.count, 4, "two media rows and two failed saves are four cards")
        XCTAssertEqual(
            deck.cardCount, 5,
            "plus the permanent util card — this is the count the archive pull reads")
        _ = window
    }

    /// The tray's pull becomes available on the LAST card, and with failed saves
    /// present that is a failed save, not the last media row.
    @MainActor
    func testArchivePullActivatesOnlyOnTheTrueLastCard() {
        seedMedia(count: 2)
        seedFailedSaves(count: 1)

        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        // The last MEDIA card, one short of the true last card once failed
        // saves follow it.
        deck.carousel.reloadData(centeringAt: 2 + deck.cardOffset - 1)
        deck.refreshArchivePullAvailability(animated: false)
        XCTAssertFalse(
            deck.archiveTray?.isPullAvailableForTesting ?? true,
            "the last media card is not the last card when a failed save follows it")

        deck.carousel.reloadData(centeringAt: deck.cardCount - 1)
        deck.refreshArchivePullAvailability(animated: false)
        XCTAssertTrue(
            deck.archiveTray?.isPullAvailableForTesting ?? false,
            "the tray opens off the end of the deck, failed saves included")
        _ = window
    }

    /// Parked on a failed-save card, a reload that changes something else must
    /// leave the user where they were. The old `centeredID` was read out of the
    /// media array only, so a failed card gave nil and the deck fell back to the
    /// first media row.
    @MainActor
    func testStayingParkedOnAFailedSaveCardAcrossAReload() {
        seedMedia(count: 2)
        var failed = seedFailedSaves(count: 2)

        let deck = MediaCardDeck.makeRoot()
        let window = UITestSupport.host(UINavigationController(rootViewController: deck))
        deck.view.layoutIfNeeded()

        // Card 3 is the first failed save (util card, two media rows, then failed).
        let parked = deck.cardCount - 2
        deck.carousel.reloadData(centeringAt: parked)
        XCTAssertEqual(deck.carousel.currentIndex, parked)
        let parkedID = deck.slots[parked - deck.cardOffset].id

        // Something the deck renders changes, without adding a save: retitle the
        // OTHER failed row so the fingerprint moves and the reload is applied.
        failed[1].title = "Retitled"
        SavesStore.shared.seedForTesting(items: failed, contents: [:])
        NotificationCenter.default.post(name: .savesChanged, object: nil)

        XCTAssertEqual(
            deck.slots[deck.carousel.currentIndex - deck.cardOffset].id, parkedID,
            "a failed-save card holds the center across a reload like any other card")
        _ = window
    }

    // MARK: - Fixtures

    @discardableResult
    private func seedMedia(count: Int) -> [SavedMediaItem] {
        SavedMediaDeckFixtures.seedMedia(count: count, prefix: "deck-slot")
    }

    /// Deliberately OLDER than the media rows. The deck orders every card by
    /// save date now that one provider builds them all, so "failed saves sit
    /// after the media rows" is a statement about their dates rather than about
    /// a second index space appended to the first.
    @discardableResult
    private func seedFailedSaves(count: Int) -> [SavedItem] {
        let base = Date().addingTimeInterval(-3600)
        let items = (0..<count).map { offset in
            SavedItem(
                seed: "deck-slot-failed-\(offset)",
                urlString: "https://broken.example.com/deck-slot-\(offset)",
                title: nil,
                dateAdded: base.addingTimeInterval(TimeInterval(-offset * 60)),
                state: .failed)
        }
        SavesStore.shared.seedForTesting(items: items, contents: [:])
        return items
    }
}

/// `SavedMediaStore.shared` is the real App Group store — there is no
/// `seedForTesting` twin for it — so a deck test that counts cards has to empty
/// it first, and put it back to empty afterwards.
enum SavedMediaDeckFixtures {

    static func emptySharedMediaStore() {
        for item in SavedMediaStore.shared.items() {
            SavedMediaStore.shared.delete(item)
        }
    }

    /// Undownloaded rows, deliberately: they need no file on disk and no Photos
    /// permission, and `purgeExpired` (which every reload runs) leaves them alone.
    @discardableResult
    static func seedMedia(
        count: Int,
        prefix: String,
        startingAt date: Date = Date()
    ) -> [SavedMediaItem] {
        (0..<count).compactMap { offset in
            try? SavedMediaStore.shared.ensureUndownloaded(
                id: UUID(),
                sourceURLString: "https://media.example.com/\(prefix)-\(offset)",
                title: "\(prefix) \(offset)",
                kind: .video,
                dateSaved: date.addingTimeInterval(TimeInterval(-offset * 60)))
        }
    }
}
