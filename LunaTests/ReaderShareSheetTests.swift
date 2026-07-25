//
//  ReaderShareSheetTests.swift
//  LunaTests
//

import LunaSocialUI
import LunaSocial
import UIKit
import XCTest
@testable import Luna

final class ReaderShareSheetTests: XCTestCase {

    func testRowsIncludeExplicitShareActions() {
        let rows = ReaderShareSheet.rows(
            includeEbook: true,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.map(\.title), ["Copy link", "Share link", "Send as email", "Share .epub"])
        XCTAssertFalse(rows.contains { $0.isPrimary })
    }

    func testEbookRowOmittedForMedia() {
        let rows = ReaderShareSheet.rows(
            includeEbook: false,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onShareEbook: {})
        XCTAssertEqual(rows.map(\.title), ["Copy link", "Share link", "Send as email"])
        XCTAssertFalse(rows.contains { $0.title.contains("epub") })
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
        XCTAssertEqual(fired, ["copy", "link", "pick", "ebook"])
    }

    /// The menu is what the share button actually presents, so it must carry the
    /// same options in the same order as the fallback sheet's rows.
    @MainActor
    func testMenuMirrorsRowsInOrder() {
        var fired: [String] = []
        let rows = ReaderShareSheet.rows(
            includeEbook: true,
            onPickFriend: { fired.append("pick") },
            onShareLink: { fired.append("link") },
            onCopyLink: { fired.append("copy") },
            onShareEbook: { fired.append("ebook") })
        let menu = ReaderShareSheet.menu(rows: rows)
        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.count, 4)
        XCTAssertEqual(actions.map(\.title), rows.map(\.title))
        XCTAssertTrue(actions.allSatisfy { $0.image != nil })
        for action in actions { action.performWithSender(nil, target: nil) }
        XCTAssertEqual(fired, ["copy", "link", "pick", "ebook"])
    }
}
