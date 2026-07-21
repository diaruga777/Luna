//
//  SavePressPolicyTests.swift
//  LunaTests
//
//  The legacy (no `intentAction`) double-save-window regime of SavePressPolicy —
//  the pre-Action-Button 12s in-app-save behavior. `DoubleSavePolicyTests` covers
//  the newer Action-Button 7s `intentAction` regime; this file is its complement.
//

import LunaSend
import LunaModels
import XCTest
@testable import Luna

final class SavePressPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)
    private let kindle = ArticleDestinationID.kindle
    /// A second, made-up destination id — `ArticleSendCoordinator`/`SavePressPolicy`
    /// treat destination ids as opaque strings, so this doesn't need to correspond
    /// to a registered `ArticleDestination`.
    private let secondDestinationID = "secondEreader"

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
        // kindle sent an hour ago (skip); the second destination never sent (send).
        var item = self.item(
            sendState: .sent, dateSent: now.addingTimeInterval(-3600), destination: kindle)
        item.sendStates[secondDestinationID] = nil
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item,
                previousPressDate: now.addingTimeInterval(-5), now: now,
                doubleSaveDestinationIDs: [kindle, secondDestinationID]),
            .sendToEreaders(destinationIDs: [secondDestinationID]))
    }

    func testDoublePressOnPlatformItemIsIgnored() {
        var video = item()
        video.platform = .tiktok
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
