//
//  ReaderShareSheetTests.swift
//  LunaTests
//

import LunaSocialUI
import LunaSocial
import XCTest
@testable import Luna

final class ReaderShareSheetTests: XCTestCase {

    func testRowsIncludeExplicitShareActions() {
        let rows = ReaderShareSheet.rows(
            includeEbook: true,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.title), ["Send to a Contact…", "Share Link…", "Copy Link", "Share eBook…"])
        XCTAssertFalse(rows.contains { $0.isPrimary })
    }

    func testEbookRowOmittedForMedia() {
        let rows = ReaderShareSheet.rows(
            includeEbook: false,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.map(\.title), ["Send to a Contact…", "Share Link…", "Copy Link"])
        XCTAssertFalse(rows.contains { $0.title.contains("eBook") })
    }

    func testEachRowInvokesItsOwnAction() {
        var fired: [String] = []
        let rows = ReaderShareSheet.rows(
            includeEbook: true,
            onPickFriend: { fired.append("pick") },
            onShareLink: { fired.append("link") },
            onCopyLink: { fired.append("copy") },
            onShareEbook: { fired.append("ebook") })
        for row in rows { row.action() }
        XCTAssertEqual(fired, ["pick", "link", "copy", "ebook"])
    }
}
