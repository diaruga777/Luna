//
//  MailSettingsMigrationTests.swift
//  LunaTests
//

import LunaMailAccount
import LunaModels
import LunaStorage
import XCTest
@testable import LunaMailTransport
@testable import LunaSend

/// The mail-import cursor and the Kindle address live in the shared App-Group
/// suite, so the central app and the Reader describe ONE connected account. Each
/// setting still answers with a value an older per-app build left in `standard`,
/// once, and copies it into the group on the way through.
final class MailSettingsMigrationTests: XCTestCase {
    private var group: UserDefaults!
    private var legacy: UserDefaults!
    private var groupSuite: String!
    private var legacySuite: String!

    override func setUp() {
        super.setUp()
        groupSuite = "MailSettingsMigrationTests.group.\(UUID().uuidString)"
        legacySuite = "MailSettingsMigrationTests.legacy.\(UUID().uuidString)"
        group = UserDefaults(suiteName: groupSuite)
        legacy = UserDefaults(suiteName: legacySuite)
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)
        IncomingMailSettings.testDefaultsOverride = store
        KindleSendSettings.testDefaultsOverride = store
        SourceSendSettings.testDefaultsOverride = store
    }

    override func tearDown() {
        IncomingMailSettings.testDefaultsOverride = nil
        KindleSendSettings.testDefaultsOverride = nil
        SourceSendSettings.testDefaultsOverride = nil
        group.removePersistentDomain(forName: groupSuite)
        legacy.removePersistentDomain(forName: legacySuite)
        group = nil
        legacy = nil
        super.tearDown()
    }

    // MARK: - The store itself

    func testReadWithNothingStoredAnywhereIsEmpty() {
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)

        XCTAssertNil(store.string(forKey: "k"))
        XCTAssertFalse(store.bool(forKey: "k"))
        XCTAssertEqual(store.integer(forKey: "k"), 0)
        XCTAssertNil(store.stringArray(forKey: "k"))
        XCTAssertNil(store.data(forKey: "k"))
    }

    func testLegacyValueIsCopiedIntoTheGroupOnFirstRead() {
        legacy.set("legacy@kindle.com", forKey: "k")
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)

        XCTAssertEqual(store.string(forKey: "k"), "legacy@kindle.com")
        XCTAssertEqual(group.string(forKey: "k"), "legacy@kindle.com")

        legacy.removeObject(forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "legacy@kindle.com")
    }

    func testGroupValueWinsOverAStaleLegacyValue() {
        group.set("group@kindle.com", forKey: "k")
        legacy.set("stale@kindle.com", forKey: "k")
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)

        XCTAssertEqual(store.string(forKey: "k"), "group@kindle.com")
    }

    func testWritesGoOnlyToTheGroup() {
        let store = MigratingAppGroupDefaults(group: group, legacy: legacy)

        store.set("written", forKey: "k")

        XCTAssertEqual(group.string(forKey: "k"), "written")
        XCTAssertNil(legacy.string(forKey: "k"))
    }

    /// With no App Group to open, group and legacy are the same store: a read
    /// must not treat the one suite as its own legacy half and loop.
    func testOneSuiteForBothHalvesStillReadsAndWrites() {
        let store = MigratingAppGroupDefaults(group: legacy, legacy: legacy)

        store.set("x", forKey: "k")

        XCTAssertEqual(store.string(forKey: "k"), "x")
    }

    // MARK: - IncomingMailSettings

    func testFreshInstallReadsTheGroupCursor() {
        IncomingMailSettings.cursor = .imap(uid: 42, uidValidity: 7)

        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 42, uidValidity: 7))
        XCTAssertNotNil(group.data(forKey: "incomingMailCursor"))
        XCTAssertNil(legacy.data(forKey: "incomingMailCursor"))
    }

    func testCursorWrittenByAnOlderBuildMigratesOnFirstRead() throws {
        let encoded = try JSONEncoder().encode(MailCursor.imap(uid: 99, uidValidity: 3))
        legacy.set(encoded, forKey: "incomingMailCursor")

        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 99, uidValidity: 3))

        legacy.removeObject(forKey: "incomingMailCursor")
        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 99, uidValidity: 3))
    }

    func testGroupCursorWinsOverAStaleLegacyCursor() throws {
        legacy.set(
            try JSONEncoder().encode(MailCursor.imap(uid: 1, uidValidity: 1)),
            forKey: "incomingMailCursor")
        IncomingMailSettings.cursor = .imap(uid: 500, uidValidity: 9)

        XCTAssertEqual(IncomingMailSettings.cursor, .imap(uid: 500, uidValidity: 9))
    }

    func testAllowedSendersMigrateFromTheLegacySuite() {
        legacy.set(["a@example.com"], forKey: "incomingMailAllowedSenders")

        XCTAssertEqual(IncomingMailSettings.allowedSenders, ["a@example.com"])

        IncomingMailSettings.addSender("b@example.com")

        XCTAssertEqual(
            group.stringArray(forKey: "incomingMailAllowedSenders"),
            ["a@example.com", "b@example.com"])
    }

    func testImportEnabledPrefersTheGroupValue() {
        legacy.set(true, forKey: "incomingMailEnabled")
        group.set(false, forKey: "incomingMailEnabled")

        XCTAssertFalse(IncomingMailSettings.isEnabled)
    }

    // MARK: - KindleSendSettings

    func testFreshInstallReadsTheGroupKindleAddress() {
        KindleSendSettings.kindleAddress = "me@kindle.com"

        XCTAssertEqual(KindleSendSettings.kindleAddress, "me@kindle.com")
        XCTAssertEqual(group.string(forKey: "kindleAddress"), "me@kindle.com")
        XCTAssertNil(legacy.string(forKey: "kindleAddress"))
    }

    func testKindleAddressAndModeMigrateFromTheLegacySuite() {
        legacy.set("old@kindle.com", forKey: "kindleAddress")
        legacy.set(ArticleSendMode.allSaves.rawValue, forKey: "kindleSendMode")

        XCTAssertEqual(KindleSendSettings.kindleAddress, "old@kindle.com")
        XCTAssertEqual(KindleSendSettings.sendMode, .allSaves)
        XCTAssertEqual(group.string(forKey: "kindleAddress"), "old@kindle.com")
    }

    func testGroupKindleAddressWinsOverAStaleLegacyAddress() {
        legacy.set("stale@kindle.com", forKey: "kindleAddress")
        KindleSendSettings.kindleAddress = "current@kindle.com"

        XCTAssertEqual(KindleSendSettings.kindleAddress, "current@kindle.com")
    }

    /// The "Also Send to Kindle" toggle is one key read by two enums in two
    /// modules; both resolve the same suite.
    func testAutoSendToKindleIsOneValueForBothSettingsEnums() {
        IncomingMailSettings.autoSendToKindle = true

        XCTAssertTrue(KindleSendSettings.autoSendToKindle)

        KindleSendSettings.autoSendToKindle = false

        XCTAssertFalse(IncomingMailSettings.autoSendToKindle)
    }

    // MARK: - SourceSendSettings

    /// The per-source toggles ("send friend shares", "send share-sheet saves")
    /// were the last `standard`-backed corner of the send settings, so the
    /// central app and the Reader each held their own answer for the ONE
    /// connected account.
    func testPerSourceTogglesWriteOnlyToTheGroup() {
        SourceSendSettings.setShareAndPasteEnabled(true, forDestination: destination)

        XCTAssertTrue(SourceSendSettings.shareAndPasteEnabled(forDestination: destination))
        XCTAssertTrue(group.bool(forKey: "send.otherEreader.sharePaste"))
        XCTAssertNil(legacy.object(forKey: "send.otherEreader.sharePaste"))
    }

    func testPerSourceToggleWrittenByAnOlderBuildMigratesOnFirstRead() {
        legacy.set(true, forKey: "send.otherEreader.friendDefault")

        XCTAssertTrue(SourceSendSettings.friendSharesEnabledDefault(forDestination: destination))
        XCTAssertTrue(group.bool(forKey: "send.otherEreader.friendDefault"))

        legacy.removeObject(forKey: "send.otherEreader.friendDefault")
        XCTAssertTrue(SourceSendSettings.friendSharesEnabledDefault(forDestination: destination))
    }

    /// A stored OFF has to survive the read-through, not fall back to the legacy
    /// "all saves" default — otherwise a Kindle user who turned share-sheet sends
    /// off gets them all back on the build that migrates them.
    func testAnOlderBuildsExplicitOffSurvivesTheMigration() {
        KindleSendSettings.sendMode = .allSaves
        legacy.set(false, forKey: "send.kindle.sharePaste")

        XCTAssertFalse(
            SourceSendSettings.shareAndPasteEnabled(forDestination: ArticleDestinationID.kindle))
        XCTAssertEqual(
            SourceSendSettings.sendMode(
                forDestination: ArticleDestinationID.kindle, source: .shareSheet,
                friendUsername: nil),
            .off)
    }

    /// The per-friend overrides are a JSON blob rather than a flag, and they
    /// migrate as one value: the first read copies the older build's map over,
    /// and a new override is merged into it in the group.
    func testFriendOverridesMigrateAndThenMergeInTheGroup() throws {
        legacy.set(
            try JSONEncoder().encode(["alice": false]),
            forKey: "send.otherEreader.friendOverrides")

        XCTAssertFalse(
            SourceSendSettings.friendShareEnabled(forDestination: destination, username: "alice"))

        SourceSendSettings.setFriendShareEnabled(
            true, forDestination: destination, username: "bob")

        XCTAssertFalse(
            SourceSendSettings.friendShareEnabled(forDestination: destination, username: "alice"),
            "the migrated override is not lost by the write that follows it")
        XCTAssertTrue(
            SourceSendSettings.friendShareEnabled(forDestination: destination, username: "bob"))
        XCTAssertNotNil(group.data(forKey: "send.otherEreader.friendOverrides"))
    }

    /// A destination other than Kindle, whose toggles are the plain stored keys.
    /// Kindle special-cases its App-Intents mode and its email toggle onto
    /// `KindleSendSettings`, so it exercises less of this.
    private var destination: String { "otherEreader" }
}
