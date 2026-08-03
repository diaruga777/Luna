//
//  WeeklySaveStoreTests.swift
//  LunaTests
//

import CryptoKit
import Foundation
import LunaWeekly
import XCTest

final class WeeklySaveStoreTests: XCTestCase {
    private var container: URL!
    private var clock = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = FileManager.default.temporaryDirectory
            .appendingPathComponent("WeeklySaveStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: container, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: container)
        container = nil
        try super.tearDownWithError()
    }

    func testDisplayRoundTripsThroughDisk() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 1), for: .article)

        let reopened = makeStore()
        XCTAssertEqual(reopened.display(for: .article)?.title, "A Title")
        XCTAssertEqual(reopened.display(for: .article)?.subtitleHost, "example.com")
        XCTAssertNil(reopened.display(for: .media))
    }

    func testAnEntryOneSecondPastThirtyDaysNoLongerExists() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0), for: .article)
        XCTAssertNotNil(store.display(for: .article))

        clock = clock.addingTimeInterval(29 * 86_400)
        XCTAssertNotNil(makeStore().display(for: .article), "29 days is still live")

        clock = clock.addingTimeInterval(86_400 + 1)
        XCTAssertNil(makeStore().display(for: .article), "30 days + 1s has aged out")
    }

    func testMonthTierStartsAtNineDays() {
        let eightDays = display(daysOld: 8).save
        XCTAssertFalse(eightDays.isMonthTier(now: clock))
        let nineDays = display(daysOld: 9).save
        XCTAssertTrue(nineDays.isMonthTier(now: clock))
        XCTAssertFalse(nineDays.isExpired(now: clock))
    }

    func testSettingAndClearingPostDidChangeWithTheKind() {
        let store = makeStore()
        let set = expectation(forNotification: WeeklySaveStore.didChange, object: nil) { note in
            note.userInfo?[WeeklySaveStore.kindKey] as? String == "media"
        }
        store.setDisplay(display(daysOld: 0, kind: .media), for: .media)
        wait(for: [set], timeout: 1)

        let cleared = expectation(forNotification: WeeklySaveStore.didChange, object: nil) { note in
            note.userInfo?[WeeklySaveStore.kindKey] as? String == "media"
        }
        store.clear(kind: .media)
        wait(for: [cleared], timeout: 1)
        XCTAssertNil(store.display(for: .media))
    }

    /// Rewriting the identical display is not a change — the util card would
    /// otherwise run its replacement animation on every foreground refresh.
    func testWritingTheSameDisplayTwiceDoesNotPostAgain() {
        let store = makeStore()
        let value = display(daysOld: 0)
        store.setDisplay(value, for: .product)

        var posts = 0
        let token = NotificationCenter.default.addObserver(
            forName: WeeklySaveStore.didChange, object: nil, queue: nil
        ) { _ in posts += 1 }
        defer { NotificationCenter.default.removeObserver(token) }

        store.setDisplay(value, for: .product)
        store.clear(kind: .article)   // never had one
        XCTAssertEqual(posts, 0)
    }

    func testLiveDisplaysFollowTheRequestedKindOrder() {
        let store = makeStore()
        store.setDisplay(display(daysOld: 0, kind: .product), for: .product)
        store.setDisplay(display(daysOld: 0), for: .article)
        XCTAssertEqual(
            store.liveDisplays(for: [.article, .media, .product]).map(\.save.kind),
            [.article, .product])
    }

    func testSeenProposalIDsPersist() {
        let store = makeStore()
        XCTAssertTrue(store.seenProposalIDs().isEmpty)
        store.markProposalsSeen(["proposal-a", "proposal-b"])
        XCTAssertEqual(makeStore().seenProposalIDs(), ["proposal-a", "proposal-b"])
        // Marking the current set replaces it, so vanished proposals are forgotten.
        store.markProposalsSeen(["proposal-b"])
        XCTAssertEqual(makeStore().seenProposalIDs(), ["proposal-b"])
    }

    // MARK: - Helpers

    private func makeStore() -> WeeklySaveStore {
        WeeklySaveStore(containerURL: container, now: { self.clock })
    }

    private func display(
        daysOld: Int, kind: WeeklySaveKind = .article
    ) -> WeeklySaveDisplay {
        let key = Curve25519.Signing.PrivateKey()
        let save = try! WeeklySigning.sign(
            kind: kind, urlString: "https://example.com/a",
            date: clock.addingTimeInterval(-Double(daysOld) * 86_400),
            privateKey: key)
        return WeeklySaveDisplay(
            save: save, title: "A Title", subtitleHost: "example.com", imageData: nil)
    }
}
