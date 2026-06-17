//
//  SourceSendSettingsTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

/// Exercises per-source auto-send resolution. Uses the Boox destination so the
/// generic (non-Kindle) keys are tested; cleans up every key it touches.
final class SourceSendSettingsTests: XCTestCase {

    private let id = ArticleDestinationID.boox
    private let keys = [
        "booxSendMode",
        "send.boox.email",
        "send.boox.sharePaste",
        "send.boox.friendDefault",
        "send.boox.friendOverrides",
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

    func testAppIntentsAndManualFollowSendMode() {
        SourceSendSettings.setAppIntentsMode(.doubleSave, forDestination: id)
        XCTAssertEqual(mode(.appIntent), .doubleSave)
        XCTAssertEqual(mode(.manual), .doubleSave)
    }

    func testEmailToggleGatesEmailOnly() {
        SourceSendSettings.setAppIntentsMode(.off, forDestination: id)
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

    func testDefaultsToLegacyAllSavesBehavior() {
        // With mode = allSaves and no explicit per-source keys, every source is on.
        SourceSendSettings.setAppIntentsMode(.allSaves, forDestination: id)
        XCTAssertEqual(mode(.email), .allSaves)
        XCTAssertEqual(mode(.shareSheet), .allSaves)
        XCTAssertEqual(mode(.friendShare, friend: "dave"), .allSaves)
    }

    func testDefaultsOffWhenLegacyModeOff() {
        SourceSendSettings.setAppIntentsMode(.off, forDestination: id)
        XCTAssertEqual(mode(.email), .off)
        XCTAssertEqual(mode(.shareSheet), .off)
        XCTAssertEqual(mode(.friendShare, friend: "erin"), .off)
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
