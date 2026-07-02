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

    func testNewestFirstOrdering() {
        store.add(email: "first@example.com")
        usleep(5000) // distinct dateAdded timestamps
        store.add(email: "second@example.com")
        XCTAssertEqual(store.items().map(\.email), ["second@example.com", "first@example.com"])
    }

    func testEmailValidation() {
        XCTAssertTrue(Friend.isValidEmail("a@b.com"))
        XCTAssertFalse(Friend.isValidEmail("not-an-email"))
        XCTAssertFalse(Friend.isValidEmail("a@b"))
    }
}
