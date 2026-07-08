//
//  SavePressPolicyTests.swift
//  LunaTests
//

import LunaSend
import LunaModels
import XCTest
@testable import Luna

final class SavePressPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let kindle = ArticleDestinationID.kindle
    private let boox = ArticleDestinationID.boox

    private func item(
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
                existingItem: nil, previousPressDate: nil, now: now,
                doubleSaveDestinationIDs: [kindle]),
            .saveNew)
    }

    func testSecondPressInsideWindowSends() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .sendToEreaders(destinationIDs: [kindle]))
    }

    func testSecondPressOutsideWindowIsIgnored() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-60), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .ignore)
    }

    func testDoublePressIgnoredWhenNoDoubleSaveDestinations() {
        // Covers both "mode off" and "all saves" (neither is in double-save mode),
        // and "not configured".
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: []),
            .ignore)
    }

    func testDoublePressIgnoredWhenSentWithinPastDay() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(sendState: .sent, dateSent: now.addingTimeInterval(-3600)),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .ignore)
    }

    func testDoublePressResendsWhenLastSentOverADayAgo() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(sendState: .sent, dateSent: now.addingTimeInterval(-25 * 60 * 60)),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .sendToEreaders(destinationIDs: [kindle]))
    }

    func testOnlyDestinationsNotRecentlySentAreEligible() {
        // kindle sent an hour ago (skip); boox never sent (send).
        var item = self.item(sendState: .sent, dateSent: now.addingTimeInterval(-3600), destination: kindle)
        item.sendStates[boox] = nil
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item,
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle, boox]),
            .sendToEreaders(destinationIDs: [boox]))
    }

    func testDoublePressOnVideoIsIgnored() {
        var video = item()
        video.youtubeVideoID = "dQw4w9WgXcQ"
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: video,
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .ignore)
    }

    func testFailedEarlierSendDoesNotBlockDoublePress() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(sendState: .failed),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle]),
            .sendToEreaders(destinationIDs: [kindle]))
    }

    // MARK: - Action Button (intentAction) regime

    private func decideIntent(
        existingItem: ReadingListItem?, previousPressDate: Date?,
        action: SavePressPolicy.IntentAction
    ) -> SavePressPolicy.Decision {
        SavePressPolicy.decide(
            existingItem: existingItem, previousPressDate: previousPressDate, now: now,
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
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-6.9), action: .sendToKindle),
            .sendToEreaders(destinationIDs: [kindle]))
    }

    func testIntentDoublePressJustOutsideSevenSecondsIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-7.1), action: .sendToKindle),
            .ignore)
    }

    func testIntentRegimeDoesNotFallBackToLegacyTwelveSecondWindow() {
        // 9 s is inside the legacy 12 s window but outside the intent 7 s window;
        // with an intentAction armed the press must NOT trigger the legacy send.
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-9), now: now,
                doubleSaveDestinationIDs: [kindle], intentAction: .sendToKindle),
            .ignore)
    }

    func testIntentKindleRespectsResendCooldown() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(sendState: .sent, dateSent: now.addingTimeInterval(-60)),
                previousPressDate: now.addingTimeInterval(-5), action: .sendToKindle),
            .ignore)
    }

    func testIntentKindleOnPlatformItemIsIgnored() {
        var video = item()
        video.youtubeVideoID = "dQw4w9WgXcQ"
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: now.addingTimeInterval(-5), action: .sendToKindle),
            .ignore)
    }

    func testIntentFriendSendReturnsEmails() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5),
                action: .sendToFriends(emails: ["a@b.com", "c@d.com"])),
            .sendToFriends(emails: ["a@b.com", "c@d.com"]))
    }

    func testIntentFriendSendWorksForPlatformItems() {
        // Friend shares email a link, so — unlike Kindle EPUBs — platform items work.
        var video = item()
        video.youtubeVideoID = "dQw4w9WgXcQ"
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: now.addingTimeInterval(-5),
                action: .sendToFriends(emails: ["a@b.com"])),
            .sendToFriends(emails: ["a@b.com"]))
    }

    func testIntentPromptFriendSelector() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), action: .promptFriendSelector),
            .promptFriendSelector)
    }
}
