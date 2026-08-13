//
//  CardDeckOrderingTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import Luna

/// ONE ordering rule, for every kind in every app: `bumpDate ?? dateAdded`,
/// descending, ties broken by id. A save sits in the same place regardless
/// of which app shows it.
///
/// Read state never affects order. `SavesStore.archivePendingFinishedItems()`
/// archives a finished read out of the deck at launch and background instead.
final class CardDeckOrderingTests: XCTestCase {

    // MARK: - The rule

    func testOrdersNewestFirstBySortDate() {
        let oldest = item("oldest", daysAgo: 7)
        let newest = item("newest", daysAgo: 0)
        let middle = item("middle", daysAgo: 3)

        XCTAssertEqual(
            KindDeckProvider.ordered([oldest, newest, middle]).map(\.id),
            [newest.id, middle.id, oldest.id])
    }

    /// `bumpDate` is the sort date when present — that is the whole mechanism by
    /// which an unarchived save, or a product whose alert just fired, comes back
    /// to the front of a deck it was buried in.
    func testBumpDateOutranksDateAdded() {
        let old = item("old", daysAgo: 30)
        var bumped = item("bumped", daysAgo: 90)
        bumped.bumpDate = Date()
        let recent = item("recent", daysAgo: 1)

        XCTAssertEqual(
            KindDeckProvider.ordered([old, recent, bumped]).map(\.id),
            [bumped.id, recent.id, old.id])
    }

    /// Same instant, stable answer — otherwise a deck reshuffles between reloads
    /// for saves that arrived in the same batch (an email import, a friend
    /// share).
    func testTiesBreakOnIDSoTheOrderIsStable() {
        let sameMoment = Date(timeIntervalSince1970: 1_000_000)
        let a = item("a", at: sameMoment)
        let b = item("b", at: sameMoment)
        let c = item("c", at: sameMoment)

        let expected = [a, b, c].sorted { $0.id.uuidString < $1.id.uuidString }.map(\.id)
        XCTAssertEqual(KindDeckProvider.ordered([c, a, b]).map(\.id), expected)
        XCTAssertEqual(KindDeckProvider.ordered([b, c, a]).map(\.id), expected)
    }

    /// A read article does not sink. Its date alone decides its position;
    /// completion is what eventually archives it away.
    func testReadStateDoesNotAffectOrder() {
        let newestRead = item("newest-read", daysAgo: 0, readState: .read)
        let olderUnread = item("older-unread", daysAgo: 2, readState: .unopened)

        XCTAssertEqual(
            KindDeckProvider.ordered([olderUnread, newestRead]).map(\.id),
            [newestRead.id, olderUnread.id])
    }

    // MARK: - Fixtures

    private func item(
        _ seed: String,
        daysAgo: TimeInterval = 0,
        at date: Date? = nil,
        readState: SavedItem.ReadState = .unopened
    ) -> SavedItem {
        SavedItem(
            seed: seed,
            urlString: "https://example.com/\(seed)",
            title: seed,
            dateAdded: date ?? Date(timeIntervalSince1970: 1_000_000 - daysAgo * 86_400),
            state: .ready,
            readState: readState)
    }
}
