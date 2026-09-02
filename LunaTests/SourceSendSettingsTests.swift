//
//  SourceSendSettingsTests.swift
//  LunaTests
//

import LunaModels
import LunaStorage
import XCTest
@testable import LunaSend

/// The per-destination auto-send settings, with the two legacy destinations
/// on their own keys and every other one on a key of its own.
final class SourceSendSettingsTests: XCTestCase {

    private var suiteName: String!
    private var group: UserDefaults!
    private var legacy: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "SourceSendSettingsTests-\(UUID().uuidString)"
        group = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".group"))
        legacy = try XCTUnwrap(UserDefaults(suiteName: suiteName + ".legacy"))
        let defaults = MigratingAppGroupDefaults(group: group, legacy: legacy)
        SourceSendSettings.testDefaultsOverride = defaults
        KindleSendSettings.testDefaultsOverride = defaults
        XteinkSendSettings.testDefaultsOverride = defaults
    }

    override func tearDown() {
        SourceSendSettings.testDefaultsOverride = nil
        KindleSendSettings.testDefaultsOverride = nil
        XteinkSendSettings.testDefaultsOverride = nil
        UserDefaults.standard.removePersistentDomain(forName: suiteName + ".group")
        UserDefaults.standard.removePersistentDomain(forName: suiteName + ".legacy")
        group = nil
        legacy = nil
        suiteName = nil
        super.tearDown()
    }

    /// A destination a user just installed must not start auto-sending every
    /// save. Its mode is off until the auto-send screen turns it on.
    func testANewDestinationDefaultsToOffAndRoundTripsItsMode() {
        let id = "app.example.reader"
        XCTAssertEqual(SourceSendSettings.appIntentsMode(forDestination: id), .off)

        SourceSendSettings.setAppIntentsMode(.allSaves, forDestination: id)
        XCTAssertEqual(SourceSendSettings.appIntentsMode(forDestination: id), .allSaves)

        SourceSendSettings.setAppIntentsMode(.off, forDestination: id)
        XCTAssertEqual(SourceSendSettings.appIntentsMode(forDestination: id), .off)
    }

    /// Two destinations keep separate answers — the key carries the id.
    func testTwoNewDestinationsDoNotShareAMode() {
        SourceSendSettings.setAppIntentsMode(.allSaves, forDestination: "app.example.one")
        XCTAssertEqual(
            SourceSendSettings.appIntentsMode(forDestination: "app.example.two"), .off)
    }

    /// The Kindle and Xteink ids predate this key and must keep reading the
    /// settings a shipped install already wrote, or every existing setup reads
    /// as "off".
    func testTheTwoLegacyIDsStillReadTheirOwnSettings() {
        KindleSendSettings.sendMode = .allSaves
        XteinkSendSettings.sendMode = .doubleSave

        XCTAssertEqual(
            SourceSendSettings.appIntentsMode(forDestination: ArticleDestinationID.kindle),
            .allSaves)
        XCTAssertEqual(
            SourceSendSettings.appIntentsMode(forDestination: ArticleDestinationID.xteink),
            .doubleSave)
        XCTAssertNil(
            group.string(forKey: "send.kindle.appIntentsMode"),
            "the legacy id must not start writing the new key")
    }

    /// A new destination's mode is what decides whether an in-app save
    /// auto-sends to it, the same resolution the two legacy ids get.
    func testTheModeDrivesTheResolvedSendModeForAnInAppSave() {
        let id = "app.example.reader"
        XCTAssertEqual(
            SourceSendSettings.sendMode(forDestination: id, source: .manual, friendUsername: nil),
            .off)

        SourceSendSettings.setAppIntentsMode(.allSaves, forDestination: id)
        XCTAssertEqual(
            SourceSendSettings.sendMode(forDestination: id, source: .manual, friendUsername: nil),
            .allSaves)
    }
}
