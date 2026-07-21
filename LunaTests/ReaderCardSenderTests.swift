//
//  ReaderCardSenderTests.swift
//  LunaTests
//

import LunaModels
import XCTest
@testable import Luna

final class ReaderCardSenderTests: XCTestCase {

    func testIncomingEmailUsesCurrentContactName() {
        var item = ReadingListItem(urlString: "https://example.com/article")
        item.captureSource = .email
        item.channelName = "Original Name"
        item.incomingSenderEmail = "sender@example.com"

        XCTAssertEqual(
            ArticleCardsViewController.resolvedSenderName(for: item) { email in
                email == "sender@example.com" ? "Renamed Contact" : nil
            },
            "Renamed Contact")
    }

    func testIncomingEmailFallsBackToCapturedName() {
        var item = ReadingListItem(urlString: "lunamail://message")
        item.captureSource = .email
        item.channelName = "Newsletter Name"
        item.incomingSenderEmail = "news@example.com"

        XCTAssertEqual(
            ArticleCardsViewController.resolvedSenderName(for: item) { _ in nil },
            "Newsletter Name")
    }

    func testNonEmailItemHasNoSenderLabel() {
        var item = ReadingListItem(urlString: "https://example.com/article")
        item.captureSource = .shareSheet
        item.channelName = "Publisher"

        XCTAssertNil(ArticleCardsViewController.resolvedSenderName(for: item) { _ in "Contact" })
    }
}
