//
//  ReaderShareSheetTests.swift
//  ClipTests
//

import XCTest
@testable import Clip

final class ReaderShareSheetTests: XCTestCase {

    func testRowsIncludeSuggestedFriendWhenPresent() {
        let rows = ReaderShareSheet.rows(
            suggestedFriendName: "alice",
            onSendToSuggested: {}, onPickFriend: {}, onShareLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.first?.title, "Send to alice")
        XCTAssertTrue(rows.first?.isPrimary ?? false)
        XCTAssertEqual(rows.map(\.title), ["Send to alice", "Send to a Friend…", "Share Link…", "Share eBook…"])
    }

    func testRowsOmitSuggestedFriendWhenAbsent() {
        let rows = ReaderShareSheet.rows(
            suggestedFriendName: nil,
            onSendToSuggested: {}, onPickFriend: {}, onShareLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows.map(\.title), ["Send to a Friend…", "Share Link…", "Share eBook…"])
        XCTAssertFalse(rows.contains { $0.isPrimary })
    }

    func testEachRowInvokesItsOwnAction() {
        var fired: [String] = []
        let rows = ReaderShareSheet.rows(
            suggestedFriendName: "bob",
            onSendToSuggested: { fired.append("suggested") },
            onPickFriend: { fired.append("pick") },
            onShareLink: { fired.append("link") },
            onShareEbook: { fired.append("ebook") })
        for row in rows { row.action() }
        XCTAssertEqual(fired, ["suggested", "pick", "link", "ebook"])
    }
}
