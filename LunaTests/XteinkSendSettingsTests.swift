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
    func testLegacyRepairRecoversCollidingNewslettersAndTransportFailuresOnly() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SavesStore(containerURL: directory)
        let id = ArticleDestinationID.xteink
        func newsletter(_ key: String) -> SavedItem {
            let item = store.add(urlString: "lunamail://" + key, source: .email)
            return store.saveContent(ArticleContent(title: "Daily Briefing", blocks: [
                ArticleContent.Block(kind: .paragraph, text: "News", links: [])
            ]), for: item)
        }
        let first = newsletter("one"), second = newsletter("two")
        for item in [first, second] {
            store.recordRemoteDelivery(for: item.id, destination: id, remoteName: "Daily-Briefing.epub")
            store.setSendState(.sent, for: item.id, destination: id)
        }
        let failed = newsletter("failed"), hard = newsletter("hard"), read = newsletter("read")
        store.markSendTerminalFailure(for: failed.id, destination: id, errorMessage: "timed out waiting for checkpoint")
        store.markSendTerminalFailure(for: hard.id, destination: id, errorMessage: "auth_failed")
        store.markSendTerminalFailure(for: read.id, destination: id, errorMessage: "sequence")
        store.markFinishedReading(read.id)
        XteinkSendSettings.repairLegacySyncQueue(store: store)
        for item in [first, second, failed] {
            XCTAssertEqual(store.item(withID: item.id)?.sendState(for: id), .queued)
        }
        XCTAssertEqual(store.item(withID: hard.id)?.sendState(for: id), .failed)
        XCTAssertEqual(store.item(withID: read.id)?.sendState(for: id), .failed)
        for item in [first, second] {
            store.recordRemoteDelivery(for: item.id, destination: id,
                remoteName: XteinkCrossPointTransferRouter.x3FileName("Daily-Briefing.epub", articleID: item.id))
            store.setSendState(.sent, for: item.id, destination: id)
        }
        XteinkSendSettings.repairLegacySyncQueue(store: store)
        XCTAssertEqual(store.item(withID: first.id)?.sendState(for: id), .sent)
        XCTAssertEqual(store.item(withID: second.id)?.sendState(for: id), .sent)
    }

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
