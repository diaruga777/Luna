//
//  SavePressPolicyTests.swift
//  LuneTests
//

import LuneSend
import LuneModels
import XCTest
@testable import Lune

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
}
