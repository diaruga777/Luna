//
//  FriendsStoreTests.swift
//  LunaTests
//

import LunaSocial
import XCTest
@testable import Luna

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

    func testAddListRemove() {
        store.add(email: "Alice@Example.com", name: "Alice")
        XCTAssertEqual(store.items().count, 1)
        // Email is normalized (lowercased) and used as the identifier.
        XCTAssertTrue(store.isFriend("alice@example.com"))
        XCTAssertEqual(store.friend(withEmail: "alice@example.com")?.displayName, "Alice")

        store.remove(email: "alice@example.com")
        XCTAssertTrue(store.items().isEmpty)
    }

    func testReAddUpdatesNameWithoutDuplicating() {
        store.add(email: "alice@example.com")
        let originalDate = store.items().first?.dateAdded
        store.add(email: "alice@example.com", name: "Alice Renamed")

        let all = store.items()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.name, "Alice Renamed")
        XCTAssertEqual(all.first?.dateAdded, originalDate)
    }

    func testDisplayNameFallsBackToLocalPart() {
        store.add(email: "bob@example.com")
        XCTAssertEqual(store.friend(withEmail: "bob@example.com")?.displayName, "bob")
    }

    func testFirstShareTracking() {
        store.add(email: "alice@example.com")
        XCTAssertTrue(store.markReceivedShare(email: "alice@example.com"))  // first
        XCTAssertFalse(store.markReceivedShare(email: "alice@example.com")) // subsequent
    }

    func testBlockMovesContactToBlockedListAndUnblockRestoresIt() {
        store.add(email: "alice@example.com", name: "Alice")

        store.setBlocked(true, email: "alice@example.com")
        XCTAssertTrue(store.isBlocked("ALICE@example.com"))
        XCTAssertTrue(store.activeItems().isEmpty)
        XCTAssertEqual(store.blockedItems().map(\.email), ["alice@example.com"])

        store.setBlocked(false, email: "alice@example.com")
        XCTAssertFalse(store.isBlocked("alice@example.com"))
        XCTAssertEqual(store.activeItems().map(\.email), ["alice@example.com"])
        XCTAssertTrue(store.blockedItems().isEmpty)
    }

    func testLegacyContactWithoutBlockedFieldDefaultsToActive() throws {
        let friend = Friend(email: "legacy@example.com", name: "Legacy")
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(friend)) as? [String: Any])
        object.removeValue(forKey: "isBlocked")
        let data = try JSONSerialization.data(withJSONObject: [object])
        try data.write(to: scratchDirectory.appendingPathComponent("friends.json"))

        XCTAssertEqual(store.activeItems().map(\.email), ["legacy@example.com"])
        XCTAssertTrue(store.blockedItems().isEmpty)
    }

    /// `items()` sorts by `dateAdded` descending. Seeded through the file
    /// rather than two `add` calls a `usleep` apart — `add` stamps `Date()`, so
    /// the old form had to burn real time just to make the two stamps differ.
    func testNewestFirstOrdering() throws {
        let older = Friend(
            email: "first@example.com", dateAdded: Date(timeIntervalSince1970: 1_000))
        let newer = Friend(
            email: "second@example.com", dateAdded: Date(timeIntervalSince1970: 2_000))
        let data = try JSONEncoder().encode([older, newer])
        try data.write(to: scratchDirectory.appendingPathComponent("friends.json"))

        XCTAssertEqual(store.items().map(\.email), ["second@example.com", "first@example.com"])
    }

    func testIndependentStoresDoNotLoseConcurrentAppGroupUpdates() {
        let firstProcess = FriendsStore(containerURL: scratchDirectory)
        let secondProcess = FriendsStore(containerURL: scratchDirectory)
        // 16 rather than 40: enough interleaving to catch a lost coordinated
        // update, without 40 serialized file-coordination round trips.
        let iterations = 16

        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let process = index.isMultiple(of: 2) ? firstProcess : secondProcess
            process.add(email: "person\(index)@example.com")
        }

        XCTAssertEqual(store.items().count, iterations)
    }

    func testEmailValidation() {
        XCTAssertTrue(Friend.isValidEmail("a@b.com"))
        XCTAssertFalse(Friend.isValidEmail("not-an-email"))
        XCTAssertFalse(Friend.isValidEmail("a@b"))
    }
}
