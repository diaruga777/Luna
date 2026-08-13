//
//  CardDeckOrderingTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import Luna

/// ONE ordering rule, for every kind in every app: `bumpDate ?? dateAdded`,
/// descending, ties broken by id.
///
/// This replaces `ArticleCardOrderingTests` and `SavedMediaCardOrderingTests`,
/// which proved two different rules over two different types because the decks
/// really did order differently — the Reader filed finished articles after
/// unopened ones and the central app could not adopt that ("read" is an
/// article-only notion; it would have filed a just-watched video behind
/// everything else), so the same save sat in a different place depending on
/// which icon you tapped.
///
/// The read/unread grouping is GONE, deliberately, and this file no longer
/// tests it. Finished reads leave the deck on their own through
/// `SavesStore.archivePendingFinishedItems()` at launch/background, which
/// is what the grouping was standing in for.
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

    /// A read article does NOT sink. The Reader used to group it last; every
    /// deck now leaves it where its date puts it, and completion is what
    /// eventually archives it away.
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
