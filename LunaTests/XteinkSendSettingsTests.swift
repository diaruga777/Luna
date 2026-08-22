//
//  XteinkSendSettingsTests.swift
//  LunaTests
//

import Foundation
import LunaModels
import LunaStorage
import XCTest
@testable import LunaSend

final class XteinkSendSettingsTests: XCTestCase {

    private var group: UserDefaults!
    private var legacy: UserDefaults!
    private var groupSuite: String!
    private var legacySuite: String!

    override func setUp() {
        super.setUp()
        groupSuite = "XteinkSendSettingsTests.group.\(UUID().uuidString)"
        legacySuite = "XteinkSendSettingsTests.legacy.\(UUID().uuidString)"
        group = UserDefaults(suiteName: groupSuite)
        legacy = UserDefaults(suiteName: legacySuite)
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)
        XteinkSendSettings.testDefaultsOverride = store
        SourceSendSettings.testDefaultsOverride = store
    }

    override func tearDown() {
        XteinkSendSettings.testDefaultsOverride = nil
        SourceSendSettings.testDefaultsOverride = nil
        group.removePersistentDomain(forName: groupSuite)
        legacy.removePersistentDomain(forName: legacySuite)
        group = nil
        legacy = nil
        super.tearDown()
    }

    /// The enable switch is the one consent step: with no stored mode, every
    /// capture source auto-sends, so flipping the switch is a complete setup.
    func testEverySourceAutoSendsByDefault() {
        let id = ArticleDestinationID.xteink
        XCTAssertEqual(SourceSendSettings.appIntentsMode(forDestination: id), .allSaves)
        XCTAssertEqual(
            SourceSendSettings.sendMode(forDestination: id, source: .shareSheet, friendUsername: nil),
            .allSaves)
        XCTAssertEqual(
            SourceSendSettings.sendMode(forDestination: id, source: .email, friendUsername: nil),
            .allSaves)
    }

    /// …while the destination stays entirely off until the switch is flipped.
    func testDisabledByDefault() {
        XCTAssertFalse(XteinkSendSettings.isConfigured)
        XCTAssertFalse(XteinkDestination().isConfigured)
    }

    func testAppIntentsModeRoundTripsThroughSourceSendSettings() {
        let id = ArticleDestinationID.xteink
        SourceSendSettings.setAppIntentsMode(.doubleSave, forDestination: id)
        XCTAssertEqual(XteinkSendSettings.sendMode, .doubleSave)
        XCTAssertEqual(SourceSendSettings.appIntentsMode(forDestination: id), .doubleSave)
    }
}
