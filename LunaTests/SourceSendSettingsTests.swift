//
//  SourceSendSettingsTests.swift
//  LunaTests
//

import LunaSend
import LunaModels
import XCTest
@testable import Luna

/// Exercises per-source auto-send resolution. `SourceSendSettings` treats
/// destination ids as opaque strings for the email/share-paste/friend-share
/// toggles, so a made-up id exercises those generic (non-Kindle) code paths —
/// Kindle is special-cased for App-Intents mode (`KindleSendSettings.sendMode`)
/// and for the email toggle (it reuses the "Also Send to Kindle" import
/// setting), so a generic id is needed to test the plain UserDefaults-backed
/// behavior. Cleans up every key it touches.
final class SourceSendSettingsTests: XCTestCase {

    private let id = "genericDestination"
    private let keys = [
        "send.genericDestination.email",
        "send.genericDestination.sharePaste",
        "send.genericDestination.friendDefault",
        "send.genericDestination.friendOverrides",
    ]

    override func setUp() {
        super.setUp()
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    private func mode(_ source: CaptureSource, friend: String? = nil) -> ArticleSendMode {
        SourceSendSettings.sendMode(forDestination: id, source: source, friendUsername: friend)
    }

    // Note: unlike the destination this file used to test (Boox, removed in
    // commit 97833a34), a generic/unregistered destination id has no
    // App-Intents mode of its own — `appIntentsMode`/`setAppIntentsMode` only
    // have a real branch for `ArticleDestinationID.kindle` today, so a
    // made-up id's App-Intents mode is always `.off` regardless of what's set.
    // That also means the "legacy all-saves inherited by default" behavior
    // (`legacyDefault`, keyed off App-Intents mode) can no longer be
    // exercised generically — it only applies to Kindle now.

    func testEmailToggleGatesEmailOnly() {
        SourceSendSettings.setEmailEnabled(true, forDestination: id)
        XCTAssertEqual(mode(.email), .allSaves)
        XCTAssertEqual(mode(.appIntent), .off)
        SourceSendSettings.setEmailEnabled(false, forDestination: id)
        XCTAssertEqual(mode(.email), .off)
    }

    func testShareSheetAndPasteShareOneToggle() {
        SourceSendSettings.setShareAndPasteEnabled(true, forDestination: id)
        XCTAssertEqual(mode(.shareSheet), .allSaves)
        XCTAssertEqual(mode(.paste), .allSaves)
        SourceSendSettings.setShareAndPasteEnabled(false, forDestination: id)
        XCTAssertEqual(mode(.shareSheet), .off)
        XCTAssertEqual(mode(.paste), .off)
    }

    func testFriendDefaultAppliesWhenNoOverride() {
        SourceSendSettings.setFriendSharesEnabledDefault(true, forDestination: id)
        XCTAssertEqual(mode(.friendShare, friend: "alice"), .allSaves)
        XCTAssertEqual(mode(.friendShare, friend: nil), .allSaves)
    }

    func testPerFriendOverrideBeatsDefault() {
        SourceSendSettings.setFriendSharesEnabledDefault(true, forDestination: id)
        SourceSendSettings.setFriendShareEnabled(false, forDestination: id, username: "bob")
        XCTAssertEqual(mode(.friendShare, friend: "bob"), .off)        // overridden off
        XCTAssertEqual(mode(.friendShare, friend: "carol"), .allSaves) // still default on
    }

    func testDefaultsOffForAllSourcesOnAGenericDestination() {
        // With no explicit per-source keys set and no App-Intents mode possible
        // for a generic id, every source defaults off.
        XCTAssertEqual(mode(.email), .off)
        XCTAssertEqual(mode(.shareSheet), .off)
        XCTAssertEqual(mode(.friendShare, friend: "dave"), .off)
        XCTAssertEqual(mode(.appIntent), .off)
        XCTAssertEqual(mode(.manual), .off)
    }
}

/// Round-trips `captureSource` through the reading-list item codec.
final class CaptureSourceCodableTests: XCTestCase {

    func testLegacyItemWithoutSourceDefaultsToManual() throws {
        let json = """
        {"id":"\(UUID().uuidString)","urlString":"https://example.com",
         "dateAdded":0,"state":"ready","readState":"unopened",
         "sendStates":{},"datesSent":{}}
        """
        let item = try JSONDecoder().decode(ReadingListItem.self, from: Data(json.utf8))
        XCTAssertNil(item.captureSource)
        XCTAssertEqual(item.effectiveCaptureSource, .manual)
    }

    func testSourceSurvivesEncodeDecode() throws {
        var item = ReadingListItem(urlString: "https://example.com")
        item.captureSource = .friendShare
        let data = try JSONEncoder().encode(item)
        let decoded = try JSONDecoder().decode(ReadingListItem.self, from: data)
        XCTAssertEqual(decoded.captureSource, .friendShare)
        XCTAssertEqual(decoded.effectiveCaptureSource, .friendShare)
    }
}
