//
//  SavePressPolicyTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class SavePressPolicyTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func item(sendState: ReadingListItem.SendState? = nil,
                      dateSent: Date? = nil) -> ReadingListItem {
        var item = ReadingListItem(urlString: "https://example.com/a")
        item.sendState = sendState
        item.dateSent = dateSent
        return item
    }

    func testNewURLSaves() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: nil, previousPressDate: nil, now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .saveNew)
    }

    func testSecondPressInsideWindowSends() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .sendToKindle)
    }

    func testSecondPressOutsideWindowIsIgnored() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-60), now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .ignore)
    }

    func testDoublePressIgnoredWhenModeIsOff() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .off, kindleConfigured: true),
            .ignore)
    }

    func testDoublePressIgnoredWhenModeIsAllSaves() {
        // All-saves mode already sent the article at ingestion; a double press
        // shouldn't trigger anything extra.
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .allSaves, kindleConfigured: true),
            .ignore)
    }

    func testDoublePressIgnoredWhenKindleNotConfigured() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .doubleSave, kindleConfigured: false),
            .ignore)
    }

    func testDoublePressIgnoredWhenSentWithinPastDay() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(sendState: .sent, dateSent: now.addingTimeInterval(-3600)),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .ignore)
    }

    func testDoublePressResendsWhenLastSentOverADayAgo() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(
                    sendState: .sent,
                    dateSent: now.addingTimeInterval(-25 * 60 * 60)),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .sendToKindle)
    }

    func testFailedEarlierSendDoesNotBlockDoublePress() {
        XCTAssertEqual(
            SavePressPolicy.decide(
                existingItem: item(sendState: .failed),
                previousPressDate: now.addingTimeInterval(-5), now: now,
                sendMode: .doubleSave, kindleConfigured: true),
            .sendToKindle)
    }
}
