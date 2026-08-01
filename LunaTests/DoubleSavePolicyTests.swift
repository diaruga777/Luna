//
//  DoubleSavePolicyTests.swift
//  LunaTests
//
//  The Action Button (7s intent) regime of SavePressPolicy, driving the
//  configurable double-save action. See claudedocs/double-save.md.
//

import LunaSend
import LunaModels
import XCTest
@testable import Luna

final class DoubleSavePolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let kindle = ArticleDestinationID.kindle

    private func item(
        sendState: ReadingListItem.SendState? = nil, dateSent: Date? = nil
    ) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/a")
        if let sendState { item.sendStates[kindle] = sendState }
        if let dateSent { item.datesSent[kindle] = dateSent }
        return item
    }

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
        video.platform = .tiktok
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
        video.platform = .tiktok
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: now.addingTimeInterval(-5),
                action: .sendToFriends(emails: ["a@b.com"])),
            .sendToFriends(emails: ["a@b.com"]))
    }

    func testIntentFriendSendWithNoEmailsIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5),
                action: .sendToFriends(emails: [])),
            .ignore)
    }

    func testIntentPromptFriendSelector() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), action: .promptFriendSelector),
            .promptFriendSelector)
    }

    // MARK: - "Nothing" (the default action)

    func testIntentDoNothingIgnoresDoublePress() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), action: .doNothing),
            .ignore)
    }

    /// The whole point of `.doNothing` over a nil `intentAction`: an Action
    /// Button save whose setting is "Nothing" must not slip into the legacy
    /// 12 s ereader regime and send anyway.
    func testIntentDoNothingDoesNotFallBackToLegacyEreaderSend() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle], intentAction: .doNothing),
            .ignore)
    }

    func testIntentDoNothingStillSavesANewURL() {
        XCTAssertEqual(
            decideIntent(existingItem: nil, previousPressDate: nil, action: .doNothing),
            .saveNew)
    }

    // MARK: - "Open …" file exports

    func testIntentExportReturnsTheRequestedFormat() {
        for format in [ArticleExportFormat.pdf, .markdown, .richText] {
            XCTAssertEqual(
                decideIntent(
                    existingItem: item(),
                    previousPressDate: now.addingTimeInterval(-5),
                    action: .exportArticle(format: format)),
                .exportArticle(format: format))
        }
    }

    func testIntentExportOutsideTheWindowIsIgnored() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-7.1),
                action: .exportArticle(format: .pdf)),
            .ignore)
    }

    /// Exports are built from stored article content, which a video/post has
    /// none of.
    func testIntentExportOnPlatformItemIsIgnored() {
        var video = item()
        video.platform = .tiktok
        XCTAssertEqual(
            decideIntent(
                existingItem: video,
                previousPressDate: now.addingTimeInterval(-5),
                action: .exportArticle(format: .pdf)),
            .ignore)
    }

    /// The Kindle resend cooldown is about not re-emailing the same article; an
    /// export sends nothing, so building the file again is always fine.
    func testIntentExportIgnoresTheResendCooldown() {
        XCTAssertEqual(
            decideIntent(
                existingItem: item(sendState: .sent, dateSent: now.addingTimeInterval(-60)),
                previousPressDate: now.addingTimeInterval(-5),
                action: .exportArticle(format: .markdown)),
            .exportArticle(format: .markdown))
    }

    func testNoPreviousPressDoesNotTrigger() {
        XCTAssertEqual(
            decideIntent(existingItem: item(), previousPressDate: nil, action: .sendToKindle),
            .ignore)
    }
}
