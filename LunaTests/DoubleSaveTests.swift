//
//  DoubleSaveTests.swift
//  LunaTests
//
//  Merges DoubleSaveActionStoreTests, DoubleSavePolicyTests,
//  SavePressPolicyTests, and ScreenshotDoublePressTests: the double-save
//  action settings store, the two `SavePressPolicy` regimes — the
//  Action-Button 7s `intentAction` regime (`DoubleSavePolicyTests`) and the
//  legacy pre-Action-Button 12s in-app-save regime (`SavePressPolicyTests`) —
//  and the screenshot double-press heuristic that sits on top of it. See
//  claudedocs/double-save.md.
//

import LunaIntents
import LunaModels
import LunaSend
@testable import LunaStorage
import XCTest
@testable import Luna

final class DoubleSaveTests: XCTestCase {

    // MARK: - DoubleSaveActionStoreTests

    private var defaults: UserDefaults!
    private var suiteName: String!
    private var now: Date!
    private var actionStore: DoubleSaveActionStore!
    private let surface = "reader"

    override func setUp() {
        super.setUp()
        suiteName = "DoubleSaveActionStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        now = Date(timeIntervalSince1970: 1_000_000)
        actionStore = DoubleSaveActionStore(defaults: defaults) { [unowned self] in now }
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    /// A double save is easy to trigger by accident, so nothing happens until
    /// the user picks an action.
    func testDefaults() {
        XCTAssertEqual(actionStore.action(forSurface: surface), .nothing)
        XCTAssertEqual(actionStore.presetFriendEmails(forSurface: surface), [])
    }

    func testSettingsRoundTrip() {
        actionStore.setAction(.openDocument, forSurface: surface)
        actionStore.setPresetFriendEmails(["a@b.com", "c@d.com"], forSurface: surface)
        XCTAssertEqual(actionStore.action(forSurface: surface), .openDocument)
        XCTAssertEqual(actionStore.presetFriendEmails(forSurface: surface), ["a@b.com", "c@d.com"])
        // Surfaces are independent: Luna and Reader each keep their own action.
        XCTAssertEqual(actionStore.action(forSurface: "luna"), .nothing)
    }

    /// The retired `sendToFriend` value can still be sitting in the shared App
    /// Group. It must read back as the inert default, not crash or linger.
    func testRetiredStoredActionFallsBackToNothing() {
        defaults.set("sendToFriend", forKey: "doubleSave.action.\(surface)")
        XCTAssertEqual(actionStore.action(forSurface: surface), .nothing)
    }

    func testRetiredFileChoicesMigrateToViewImmediately() {
        for retiredValue in ["openPDF", "openMarkdown"] {
            defaults.set(retiredValue, forKey: "doubleSave.action.\(surface)")
            XCTAssertEqual(actionStore.action(forSurface: surface), .openDocument)
        }
    }

    /// The single View immediately action returns the self-contained Word
    /// document; the inert/Kindle actions return no file.
    func testExportFormats() {
        XCTAssertNil(DoubleSaveAction.nothing.exportFormat)
        XCTAssertNil(DoubleSaveAction.sendToKindle.exportFormat)
        XCTAssertEqual(DoubleSaveAction.openDocument.exportFormat, .document)
    }

    func testPendingFriendPromptIsOneShot() {
        actionStore.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        XCTAssertEqual(
            actionStore.takePendingFriendPrompt(forSurface: surface), "https://example.com/a")
        XCTAssertNil(
            actionStore.takePendingFriendPrompt(forSurface: surface), "second take must be empty")
    }

    func testPendingFriendPromptExpires() {
        actionStore.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        now = now.addingTimeInterval(DoubleSaveActionStore.friendPromptLifetime + 1)
        XCTAssertNil(actionStore.takePendingFriendPrompt(forSurface: surface))
    }

    func testPendingFriendPromptIsPerSurface() {
        actionStore.setPendingFriendPrompt(urlString: "https://example.com/a", forSurface: surface)
        XCTAssertNil(actionStore.takePendingFriendPrompt(forSurface: "downloader"))
        XCTAssertEqual(
            actionStore.takePendingFriendPrompt(forSurface: surface), "https://example.com/a")
    }

    // MARK: - DoubleSavePolicyTests
    //
    // The Action Button (7s `intentAction`) regime of SavePressPolicy, driving
    // the configurable double-save action. See claudedocs/double-save.md.

    private let intentRegimeNow = Date(timeIntervalSince1970: 1_000_000)
    private let intentRegimeKindle = ArticleDestinationID.kindle

    private func intentRegimeItem(
        sendState: ReadingListItem.SendState? = nil, dateSent: Date? = nil
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/a")
        if let sendState { item.sendStates[intentRegimeKindle] = sendState }
        if let dateSent { item.datesSent[intentRegimeKindle] = dateSent }
        return item
    }

    private func decideIntent(
        existingItem: ReadingListItem?, previousPressDate: Date?,
        action: SavePressPolicy.IntentAction
    ) -> SavePressPolicy.Decision {
        SavePressPolicy.decide(
            existingItem: existingItem, previousPressDate: previousPressDate, now: intentRegimeNow,
            doubleSaveDestinationIDs: [], intentAction: action)
    }

    func testIntentNewURLSaves() {
        XCTAssertEqual(
            decideIntent(existingItem: nil, previousPressDate: nil, action: .sendToKindle),
            .saveNew)
    }

    func testIntentDoublePressJustInsideSevenSecondsTriggers() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-6.9), action: .sendToKindle),
            .sendToEreaders(destinationIDs: [intentRegimeKindle]))
    }

    func testIntentDoublePressWithNoGapTriggers() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(), previousPressDate: intentRegimeNow,
                action: .sendToKindle),
            .sendToEreaders(destinationIDs: [intentRegimeKindle]))
    }

    func testOverlappingIntentStartDatesMayArriveInReverseOrder() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(0.25),
                action: .exportArticle(format: .document)),
            .exportArticle(format: .document))
    }

    func testReverseOrderedIntentStartsStillRespectTheSevenSecondWindow() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(7.1),
                action: .exportArticle(format: .document)),
            .ignore)
    }

    func testIntentDoublePressJustOutsideSevenSecondsIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-7.1), action: .sendToKindle),
            .ignore)
    }

    func testIntentRegimeDoesNotFallBackToLegacyTwelveSecondWindow() {
        // 9 s is inside the legacy 12 s window but outside the intent 7 s window;
        // with an intentAction armed the press must NOT trigger the legacy send.
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-9), now: intentRegimeNow,
                doubleSaveDestinationIDs: [intentRegimeKindle], intentAction: .sendToKindle),
            .ignore)
    }

    func testIntentKindleRespectsResendCooldown() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(
                    sendState: .sent, dateSent: intentRegimeNow.addingTimeInterval(-60)),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5), action: .sendToKindle),
            .ignore)
    }

    func testIntentKindleOnPlatformItemIsIgnored() {
        var video = intentRegimeItem()
        video.platform = .tiktok
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: intentRegimeNow.addingTimeInterval(-5), action: .sendToKindle),
            .ignore)
    }

    func testIntentFriendSendReturnsEmails() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                action: .sendToFriends(emails: ["a@b.com", "c@d.com"])),
            .sendToFriends(emails: ["a@b.com", "c@d.com"]))
    }

    func testIntentFriendSendWorksForPlatformItems() {
        // Friend shares email a link, so — unlike Kindle EPUBs — platform items work.
        var video = intentRegimeItem()
        video.platform = .tiktok
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                action: .sendToFriends(emails: ["a@b.com"])),
            .sendToFriends(emails: ["a@b.com"]))
    }

    func testIntentFriendSendWithNoEmailsIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                action: .sendToFriends(emails: [])),
            .ignore)
    }

    func testIntentPromptFriendSelector() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5), action: .promptFriendSelector),
            .promptFriendSelector)
    }

    // MARK: DoubleSavePolicyTests: "Nothing" (the default action)

    func testIntentDoNothingIgnoresDoublePress() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5), action: .doNothing),
            .ignore)
    }

    /// The whole point of `.doNothing` over a nil `intentAction`: an Action
    /// Button save whose setting is "Nothing" must not slip into the legacy
    /// 12 s ereader regime and send anyway.
    func testIntentDoNothingDoesNotFallBackToLegacyEreaderSend() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5), now: intentRegimeNow,
                doubleSaveDestinationIDs: [intentRegimeKindle], intentAction: .doNothing),
            .ignore)
    }

    func testIntentDoNothingStillSavesANewURL() {
        XCTAssertEqual(
            decideIntent(existingItem: nil, previousPressDate: nil, action: .doNothing),
            .saveNew)
    }

    // MARK: DoubleSavePolicyTests: Article file exports

    func testIntentExportReturnsTheRequestedFormat() {
        for format in [ArticleExportFormat.pdf, .markdown, .document] {
            XCTAssertEqual(
                decideIntent(
                    existingItem: intentRegimeItem(),
                    previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                    action: .exportArticle(format: format)),
                .exportArticle(format: format))
        }
    }

    func testIntentExportOutsideTheWindowIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(),
                previousPressDate: intentRegimeNow.addingTimeInterval(-7.1),
                action: .exportArticle(format: .pdf)),
            .ignore)
    }

    /// Exports are built from stored article content, which a video/post has
    /// none of.
    func testIntentExportOnPlatformItemIsIgnored() {
        var video = intentRegimeItem()
        video.platform = .tiktok
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                action: .exportArticle(format: .pdf)),
            .ignore)
    }

    /// The Kindle resend cooldown is about not re-emailing the same article; an
    /// export sends nothing, so building the file again is always fine.
    func testIntentExportIgnoresTheResendCooldown() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(
                    sendState: .sent, dateSent: intentRegimeNow.addingTimeInterval(-60)),
                previousPressDate: intentRegimeNow.addingTimeInterval(-5),
                action: .exportArticle(format: .markdown)),
            .exportArticle(format: .markdown))
    }

    func testNoPreviousPressDoesNotTrigger() {
        XCTAssertEqual(
            decideIntent(
                existingItem: intentRegimeItem(), previousPressDate: nil, action: .sendToKindle),
            .ignore)
    }

    // MARK: - SavePressPolicyTests
    //
    // The legacy (no `intentAction`) double-save-window regime of
    // SavePressPolicy — the pre-Action-Button 12s in-app-save behavior.
    // `DoubleSavePolicyTests` above covers the newer Action-Button 7s
    // `intentAction` regime; this section is its complement.

    private let legacyRegimeNow = Date(timeIntervalSince1970: 1_000_000)
    private let legacyRegimeKindle = ArticleDestinationID.kindle
    /// A second, made-up destination id — `ArticleSendCoordinator`/`SavePressPolicy`
    /// treat destination ids as opaque strings, so this doesn't need to correspond
    /// to a registered `ArticleDestination`.
    private let legacyRegimeSecondDestinationID = "secondEreader"

    private func legacyRegimeItem(
        sendState: ReadingListItem.SendState? = nil, dateSent: Date? = nil,
        destination: String = ArticleDestinationID.kindle
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/a")
        if let sendState { item.sendStates[destination] = sendState }
        if let dateSent { item.datesSent[destination] = dateSent }
        return item
    }

    func testNewURLSaves() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: nil, previousPressDate: nil, now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .saveNew)
    }

    func testSecondPressInsideWindowSends() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .sendToEreaders(destinationIDs: [legacyRegimeKindle]))
    }

    func testSecondPressOutsideWindowIsIgnored() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-60), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .ignore)
    }

    func testDoublePressIgnoredWhenNoDoubleSaveDestinations() {
        // Covers both "mode off" and "all saves" (neither is in double-save mode),
        // and "not configured".
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: []),
            .ignore)
    }

    func testDoublePressIgnoredWhenSentWithinPastDay() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(
                    sendState: .sent, dateSent: legacyRegimeNow.addingTimeInterval(-3600)),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .ignore)
    }

    func testDoublePressResendsWhenLastSentOverADayAgo() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(
                    sendState: .sent, dateSent: legacyRegimeNow.addingTimeInterval(-25 * 60 * 60)),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .sendToEreaders(destinationIDs: [legacyRegimeKindle]))
    }

    func testOnlyDestinationsNotRecentlySentAreEligible() {
        // kindle sent an hour ago (skip); the second destination never sent (send).
        var item = legacyRegimeItem(
            sendState: .sent, dateSent: legacyRegimeNow.addingTimeInterval(-3600),
            destination: legacyRegimeKindle)
        item.sendStates[legacyRegimeSecondDestinationID] = nil
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item,
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle, legacyRegimeSecondDestinationID]),
            .sendToEreaders(destinationIDs: [legacyRegimeSecondDestinationID]))
    }

    func testDoublePressOnPlatformItemIsIgnored() {
        var video = legacyRegimeItem()
        video.platform = .tiktok
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: video,
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .ignore)
    }

    func testFailedEarlierSendDoesNotBlockDoublePress() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: legacyRegimeItem(sendState: .failed),
                previousPressDate: legacyRegimeNow.addingTimeInterval(-5), now: legacyRegimeNow,
                doubleSaveDestinationIDs: [legacyRegimeKindle]),
            .sendToEreaders(destinationIDs: [legacyRegimeKindle]))
    }

    // MARK: - ScreenshotDoublePressTests

    private func digest(_ byte: UInt8) -> Data {
        Data(repeating: byte, count: ScreenshotDigest.side * ScreenshotDigest.side)
    }

    func testNilPreviousRunsModel() {
        XCTAssertEqual(ScreenshotDoublePress.decide(newDigest: digest(10), previous: nil), .runModel)
    }

    func testSimilarAndRecentIsDoublePress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-2), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    func testSimilarWithNoGapIsDoublePress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now, savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    func testSimilarOverlappingStartsMayArriveInReverseOrder() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(0.25),
            savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    func testSimilarButOldRunsModel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-30), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now), .runModel)
    }

    func testDissimilarButRecentRunsModel() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10), date: now.addingTimeInterval(-2), savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(200), previous: previous, now: now), .runModel)
    }

    func testExactlyAtWindowBoundaryRunsModel() {
        // SavePressPolicy.intentDoublePressWindow is compared with a strict
        // `<`, so exactly at the boundary already counts as stale.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10),
            date: now.addingTimeInterval(-SavePressPolicy.intentDoublePressWindow),
            savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now), .runModel)
    }

    func testJustInsideWindowIsDoublePress() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let previous = ScreenshotDoublePressSnapshot(
            digest: digest(10),
            date: now.addingTimeInterval(-(SavePressPolicy.intentDoublePressWindow - 0.5)),
            savedURLString: "https://example.com/a")
        XCTAssertEqual(
            ScreenshotDoublePress.decide(newDigest: digest(10), previous: previous, now: now),
            .treatAsDoublePress(savedURLString: "https://example.com/a"))
    }

    // MARK: ScreenshotDoublePressTests: ScreenshotDoublePressStore round trip (injected App-Group suite)

    func testStoreRoundTrip() {
        let suiteName = "ScreenshotDoublePressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        ScreenshotDoublePressStore.testDefaultsOverride = defaults
        defer {
            ScreenshotDoublePressStore.testDefaultsOverride = nil
            defaults?.removePersistentDomain(forName: suiteName)
        }

        XCTAssertNil(ScreenshotDoublePressStore.last())

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        ScreenshotDoublePressStore.record(digest: digest(42), savedURLString: "https://example.com/b", now: now)

        let last = ScreenshotDoublePressStore.last()
        XCTAssertEqual(last?.digest, digest(42))
        XCTAssertEqual(last?.savedURLString, "https://example.com/b")
        XCTAssertEqual(last?.date, now)
    }

    func testStoreCompletionExtendsTimestampAndNeverMovesItBackward() {
        let suiteName = "ScreenshotDoublePressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        ScreenshotDoublePressStore.testDefaultsOverride = defaults
        defer {
            ScreenshotDoublePressStore.testDefaultsOverride = nil
            defaults?.removePersistentDomain(forName: suiteName)
        }

        let startedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let url = "https://example.com/end-window"
        ScreenshotDoublePressStore.record(
            digest: digest(42), savedURLString: url, now: startedAt)
        let completedAt = startedAt.addingTimeInterval(18)
        ScreenshotDoublePressStore.finish(
            digest: digest(42), savedURLString: url, at: completedAt)
        XCTAssertEqual(ScreenshotDoublePressStore.last()?.date, completedAt)

        ScreenshotDoublePressStore.record(
            digest: digest(42), savedURLString: url,
            now: startedAt.addingTimeInterval(2))
        XCTAssertEqual(ScreenshotDoublePressStore.last()?.date, completedAt)
    }

    func testOlderRunCannotFinishOverANewerDifferentScreenshot() {
        let suiteName = "ScreenshotDoublePressTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)
        ScreenshotDoublePressStore.testDefaultsOverride = defaults
        defer {
            ScreenshotDoublePressStore.testDefaultsOverride = nil
            defaults?.removePersistentDomain(forName: suiteName)
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        ScreenshotDoublePressStore.record(
            digest: digest(10), savedURLString: "https://example.com/old", now: now)
        ScreenshotDoublePressStore.record(
            digest: digest(200), savedURLString: "https://example.com/new",
            now: now.addingTimeInterval(1))
        ScreenshotDoublePressStore.finish(
            digest: digest(10), savedURLString: "https://example.com/old",
            at: now.addingTimeInterval(20))

        XCTAssertEqual(ScreenshotDoublePressStore.last()?.digest, digest(200))
        XCTAssertEqual(
            ScreenshotDoublePressStore.last()?.savedURLString, "https://example.com/new")
    }
}
