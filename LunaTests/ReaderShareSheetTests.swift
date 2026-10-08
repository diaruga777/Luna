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

    /// Fires a row's action if it's a `.tap`; a `.submenu` row fires nothing
    /// itself (tapping it opens its children instead).
    private func fire(_ row: ReaderShareSheet.Row) {
        if case .tap(let action) = row.behavior { action() }
    }

    private func isSubmenu(_ row: ReaderShareSheet.Row) -> Bool {
        if case .submenu = row.behavior { return true }
        return false
    }

    private func children(of row: ReaderShareSheet.Row) -> [ReaderShareSheet.Row] {
        if case .submenu(let children) = row.behavior { return children }
        return []
    }

    func testRowsIncludeExplicitShareActions() {
        let rows = ReaderShareSheet.rows(
            includeExport: true,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onExport: { _ in })
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(
            rows.map(\.title), ["Copy link", "Share link", "Send as email", "Export as…"])
    }

    func testExportRowOmittedForMedia() {
        let rows = ReaderShareSheet.rows(
            includeExport: false,
            onPickFriend: {}, onShareLink: {}, onCopyLink: {}, onExport: { _ in })
        XCTAssertEqual(rows.map(\.title), ["Copy link", "Share link", "Send as email"])
        XCTAssertFalse(rows.contains(where: isSubmenu))
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
        let exportChildren = rows.last.map(children) ?? []
        XCTAssertEqual(exportChildren.count, ArticleExportFormat.shareMenuFormats.count)
        XCTAssertEqual(exportChildren.map(\.title), ["EPUB", "EPUB (Small, Black & White)", "PDF", "Word Document", "Text"])
        exportChildren.forEach(fire)
        XCTAssertEqual(picked, [.epub, .compactEpub, .pdf, .document, .plainText])
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
        rows.forEach(fire)
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
            fired.suffix(5), ["export:epub", "export:compactEpub", "export:pdf", "export:document", "export:plainText"])
    }
}
