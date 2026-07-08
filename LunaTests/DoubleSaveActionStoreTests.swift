//
//  DoubleSaveActionStoreTests.swift
//  LunaTests
//

import LunaStorage
import XCTest

final class DoubleSaveActionStoreTests: XCTestCase {

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var now: Date!
    private var store: DoubleSaveActionStore!
    private let surface = "reader"

    override func setUp() {
        super.setUp()
        suiteName = "DoubleSaveActionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        now = Date(timeIntervalSince1970: 1_000_000)
        store = DoubleSaveActionStore(defaults: defaults) { [unowned self] in now }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaults() {
        XCTAssertEqual(store.action(forSurface: surface), .sendToKindle)
        XCTAssertEqual(store.friendMode(forSurface: surface), .askEveryTime)
        XCTAssertEqual(store.presetFriendEmails(forSurface: surface), [])
    }

    func testSettingsRoundTrip() {
        store.setAction(.sendToFriend, forSurface: surface)
        store.setFriendMode(.preset, forSurface: surface)
        store.setPresetFriendEmails(["a@b.com", "c@d.com"], forSurface: surface)
        XCTAssertEqual(store.action(forSurface: surface), .sendToFriend)
        XCTAssertEqual(store.friendMode(forSurface: surface), .preset)
        XCTAssertEqual(store.presetFriendEmails(forSurface: surface), ["a@b.com", "c@d.com"])
        // Surfaces are independent.
        XCTAssertEqual(store.action(forSurface: "downloader"), .sendToKindle)
    }

    func testPendingFriendPromptIsOneShot() {
        store.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        XCTAssertEqual(store.takePendingFriendPrompt(forSurface: surface), "https://example.com/a")
        XCTAssertNil(store.takePendingFriendPrompt(forSurface: surface), "second take must be empty")
    }

    func testPendingFriendPromptExpires() {
        store.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        now = now.addingTimeInterval(DoubleSaveActionStore.friendPromptLifetime + 1)
        XCTAssertNil(store.takePendingFriendPrompt(forSurface: surface))
    }

    func testPendingFriendPromptIsPerSurface() {
        store.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        XCTAssertNil(store.takePendingFriendPrompt(forSurface: "downloader"))
        XCTAssertEqual(store.takePendingFriendPrompt(forSurface: surface), "https://example.com/a")
    }
}
