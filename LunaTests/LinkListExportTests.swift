//
//  LinkListExportTests.swift
//  LunaTests
//

import LunaModels
import LunaURLClassification
import XCTest
@testable import Luna

/// What Settings ▸ Import & Export writes out, and what it accepts back
/// (`claudedocs/import-export.md`).
final class LinkListExportTests: XCTestCase {

    private func item(
        _ urlString: String, archived: Bool = false, title: String? = nil
    ) -> SavedItem {
        var item = SavedItem(urlString: urlString)
        item.title = title
        if archived { item.archivedAt = Date() }
        return item
    }

    // MARK: - What gets exported

    func testExportSeparatesTheArchiveFromTheLiveList() {
        let document = LinkListExport.document(for: [
            item("https://a.example/1"),
            item("https://b.example/2", archived: true),
            item("https://c.example/3"),
        ])
        XCTAssertEqual(document.links, ["https://a.example/1", "https://c.example/3"])
        XCTAssertEqual(document.archived, ["https://b.example/2"])
        XCTAssertTrue(document.isStructured)
    }

    func testExportKeepsStoredOrderSoAReimportReproducesIt() {
        let urls = (1...5).map { "https://example.com/\($0)" }
        let document = LinkListExport.document(for: urls.map { item($0) })
        XCTAssertEqual(document.links, urls)
    }

    func testExportLeavesOutSyntheticURLsThatAreNotLinks() {
        // `lunadoc://`/`lunamail://` name bytes inside one device's container, so
        // they would import as nothing anywhere else.
        let document = LinkListExport.document(for: [
            item("https://a.example/1"),
            item("lunadoc://ABCDEF"),
            item("lunamail://message/42"),
        ])
        XCTAssertEqual(document.links, ["https://a.example/1"])
    }

    func testExportCarriesEachSavesTitleSoAReimportNeedsNoFetch() {
        let document = LinkListExport.document(for: [
            item("https://a.example/1", title: "First Piece"),
            item("https://b.example/2"),
        ])
        XCTAssertEqual(document.titles, ["https://a.example/1": "First Piece"])
    }

    func testAnExportedFileReadsBackIdentically() throws {
        let document = LinkListExport.document(for: [
            item("https://a.example/1?ids=1,2", title: "Commas, and more"),
            item("https://b.example/2", archived: true),
        ])
        let url = try LinkListExport.writeTemporaryFile(document)
        defer { try? FileManager.default.removeItem(at: url) }

        let reread = LinkListExport.readDocument(at: url)
        XCTAssertEqual(reread?.links, document.links)
        XCTAssertEqual(reread?.archived, document.archived)
        XCTAssertEqual(reread?.titles, document.titles)
        XCTAssertEqual(reread?.isStructured, true)
    }

    func testExportFileNameCarriesTheAppAndTheDate() throws {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 5
        let date = Calendar(identifier: .gregorian).date(from: components)!
        let url = try LinkListExport.writeTemporaryFile(
            LinkListDocument(links: ["https://a.example/1"], isStructured: true), now: date)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertTrue(url.lastPathComponent.hasSuffix("-2026-08-05.md"), url.lastPathComponent)
        XCTAssertTrue(url.lastPathComponent.hasPrefix("Luna"), url.lastPathComponent)
    }

    // MARK: - Reading a picked file

    func testUTF8IsDecodedFirst() {
        let text = "section,url\nlist,https://a.example/café\n"
        XCTAssertEqual(LinkListExport.decodeText(Data(text.utf8)), text)
    }

    func testUTF16WithABOMIsDecoded() throws {
        // What a spreadsheet saving "Unicode text" produces.
        let text = "section,url\nlist,https://a.example/1\n"
        let data = try XCTUnwrap(text.data(using: .utf16))
        XCTAssertEqual(LinkListExport.decodeText(data), text)
    }

    func testUndecodableBytesStillYieldTextRatherThanRejectingTheFile() {
        // Latin-1 cannot fail, so one bad byte never costs the user their links.
        let data = Data([0x68, 0x74, 0x74, 0x70, 0xFF, 0xFE, 0x0A])
        XCTAssertNotNil(LinkListExport.decodeText(data))
    }

    func testAMissingFileIsReportedRatherThanCrashing() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).md")
        XCTAssertNil(LinkListExport.readDocument(at: missing))
    }
}
