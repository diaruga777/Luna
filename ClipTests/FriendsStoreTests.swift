//
//  FriendsStoreTests.swift
//  ClipTests
//

import ClipSocial
import XCTest
@testable import Clip

final class FriendsStoreTests: XCTestCase {

    private var store: FriendsStore!
    private var scratchDirectory: URL!

    override func setUp() {
        super.setUp()
        scratchDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FriendsStoreTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratchDirectory, withIntermediateDirectories: true)
        store = FriendsStore(containerURL: scratchDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: scratchDirectory)
        super.tearDown()
    }

    private func makeCard(username: String = "alice") -> IdentityCard {
        IdentityCard(
            uuid: UUID(), username: username, email: nil, phone: nil,
            encryptionPublicKey: Data(repeating: 1, count: 32),
            signingPublicKey: Data(repeating: 2, count: 32))
    }

    func testAddListDelete() {
        let card = makeCard()
        store.add(card)
        XCTAssertEqual(store.items().count, 1)
        XCTAssertEqual(store.friend(withUUID: card.uuid)?.card, card)

        store.delete(uuid: card.uuid)
        XCTAssertTrue(store.items().isEmpty)
    }

    func testReAddUpdatesProfileWithoutDuplicating() {
        var card = makeCard(username: "alice")
        store.add(card)
        let originalDate = store.items().first?.dateAdded

        card.username = "alice-renamed"
        card.email = "alice@example.com"
        card.signingPublicKey = Data(repeating: 9, count: 32)
        store.add(card)

        let all = store.items()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.card.username, "alice-renamed")
        XCTAssertEqual(all.first?.card.signingPublicKey, Data(repeating: 9, count: 32))
        XCTAssertEqual(all.first?.dateAdded, originalDate)
    }

    func testNewestFirstOrdering() {
        store.add(makeCard(username: "first"))
        usleep(5000) // distinct dateAdded timestamps
        store.add(makeCard(username: "second"))
        XCTAssertEqual(store.items().map(\.card.username), ["second", "first"])
    }
}
