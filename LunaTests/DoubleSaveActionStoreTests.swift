//
//  DoubleSaveActionStoreTests.swift
//  LunaTests
//

import LunaModels
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

    /// A double save is easy to trigger by accident, so nothing happens until
    /// the user picks an action.
    func testDefaults() {
        XCTAssertEqual(store.action(forSurface: surface), .nothing)
        XCTAssertEqual(store.friendMode(forSurface: surface), .askEveryTime)
        XCTAssertEqual(store.presetFriendEmails(forSurface: surface), [])
    }

    func testSettingsRoundTrip() {
        store.setAction(.openDocument, forSurface: surface)
        store.setFriendMode(.preset, forSurface: surface)
        store.setPresetFriendEmails(["a@b.com", "c@d.com"], forSurface: surface)
        XCTAssertEqual(store.action(forSurface: surface), .openDocument)
        XCTAssertEqual(store.friendMode(forSurface: surface), .preset)
        XCTAssertEqual(store.presetFriendEmails(forSurface: surface), ["a@b.com", "c@d.com"])
        // Surfaces are independent: Luna and Reader each keep their own action.
        XCTAssertEqual(store.action(forSurface: "luna"), .nothing)
    }

    /// The retired `sendToFriend` value can still be sitting in the shared App
    /// Group. It must read back as the inert default, not crash or linger.
    func testRetiredStoredActionFallsBackToNothing() {
        defaults.set("sendToFriend", forKey: "doubleSave.action.\(surface)")
        XCTAssertEqual(store.action(forSurface: surface), .nothing)
    }

    func testRetiredFileChoicesMigrateToViewImmediately() {
        for retiredValue in ["openPDF", "openMarkdown"] {
            defaults.set(retiredValue, forKey: "doubleSave.action.\(surface)")
            XCTAssertEqual(store.action(forSurface: surface), .openDocument)
        }
    }

    /// The single View immediately action returns the self-contained Rich Text
    /// document; the inert/Kindle actions return no file.
    func testExportFormats() {
        XCTAssertNil(DoubleSaveAction.nothing.exportFormat)
        XCTAssertNil(DoubleSaveAction.sendToKindle.exportFormat)
        XCTAssertEqual(DoubleSaveAction.openDocument.exportFormat, .richText)
        XCTAssertEqual(DoubleSaveAction.openDocument.displayName, "View immediately")
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
