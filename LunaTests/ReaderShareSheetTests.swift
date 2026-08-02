//
//  ReaderShareSheetTests.swift
//  LunaTests
//

import LunaModels
import LunaSocialUI
import LunaSocial
import UIKit
import XCTest
@testable import Luna

final class ReaderShareSheetTests: XCTestCase {

    func testRowsIncludeExplicitShareActions() {
        let rows = ReaderShareSheet.rows(
            includeExport: true,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onExport: { _ in })
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(
            rows.map(\.title), ["Copy link", "Share link", "Send as email", "Export as…"])
        XCTAssertFalse(rows.contains { $0.isPrimary })
    }

    func testExportRowOmittedForMedia() {
        let rows = ReaderShareSheet.rows(
            includeExport: false,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onExport: { _ in })
        XCTAssertEqual(rows.map(\.title), ["Copy link", "Share link", "Send as email"])
        XCTAssertFalse(rows.contains { !$0.children.isEmpty })
    }

    /// The export row is a submenu of every SHARE-MENU format, in
    /// `ArticleExportFormat.shareMenuFormats` order, and each child reports its
    /// own format. `.markdown` is deliberately not among them — the menu offers
    /// the Word document the double save also returns
    /// (claudedocs/double-save.md) in its place.
    func testExportRowOffersEveryFormatInOrder() {
        var picked: [ArticleExportFormat] = []
        let rows = ReaderShareSheet.rows(
            includeExport: true,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {},
            onExport: { picked.append($0) })
        let children = rows.last?.children ?? []
        XCTAssertEqual(children.count, ArticleExportFormat.shareMenuFormats.count)
        XCTAssertEqual(children.map(\.title), ["EPUB", "PDF", "Word Document", "Text"])
        for child in children { child.action() }
        XCTAssertEqual(picked, [.epub, .pdf, .document, .plainText])
    }

    func testEachRowInvokesItsOwnAction() {
        var fired: [String] = []
        let rows = ReaderShareSheet.rows(
            includeExport: true,
            onPickFriend: { fired.append("pick") },
            onShareLink: { fired.append("link") },
            onCopyLink: { fired.append("copy") },
            onExport: { fired.append("export:\($0.rawValue)") })
        // The export row is a submenu, so tapping it fires nothing itself.
        for row in rows { row.action() }
        XCTAssertEqual(fired, ["copy", "link", "pick"])
    }

    /// The menu is what the share button actually presents, so it must carry the
    /// same options in the same order as the fallback sheet's rows.
    @MainActor
    func testMenuMirrorsRowsInOrder() {
        var fired: [String] = []
        let rows = ReaderShareSheet.rows(
            includeExport: true,
            onPickFriend: { fired.append("pick") },
            onShareLink: { fired.append("link") },
            onCopyLink: { fired.append("copy") },
            onExport: { fired.append("export:\($0.rawValue)") })
        let menu = ReaderShareSheet.menu(rows: rows)
        XCTAssertEqual(menu.children.count, 4)
        XCTAssertEqual(menu.children.map(\.title), rows.map(\.title))

        let actions = menu.children.compactMap { $0 as? UIAction }
        XCTAssertEqual(actions.count, 3)
        for action in actions { action.performWithSender(nil, target: nil) }
        XCTAssertEqual(fired, ["copy", "link", "pick"])

        // The fourth element is the nested export submenu.
        let submenu = menu.children.last as? UIMenu
        XCTAssertEqual(submenu?.title, "Export as…")
        let formatActions = (submenu?.children ?? []).compactMap { $0 as? UIAction }
        XCTAssertEqual(formatActions.count, ArticleExportFormat.shareMenuFormats.count)
        XCTAssertTrue(formatActions.allSatisfy { $0.image != nil })
        for action in formatActions { action.performWithSender(nil, target: nil) }
        XCTAssertEqual(
            fired.suffix(4), ["export:epub", "export:pdf", "export:document", "export:plainText"])
    }
}
